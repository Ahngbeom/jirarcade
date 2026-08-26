import Foundation

/// 앱 동작 설정. 게임 규칙(`RuleSet`)과 섞지 않는다 —
/// 이 값들은 점수에 영향을 주지 않고, 사용자가 규칙을 재집계해도 바뀌지 않는다.
public struct AppSettings: Sendable, Equatable {
    public var syncInterval: Duration
    /// 창이 포그라운드로 왔을 때, 마지막 동기화가 이 시간 이내면 건너뛴다.
    public var foregroundCooldown: Duration
    /// 연속 실패 시 재시도 간격. 5초 → 30초 → 2분 → 10분(상한)
    public var backoffSteps: [Duration]
    /// 이 횟수만큼 연속 실패해야 UI에 표시한다.
    public var failuresBeforeSurfacing: Int
    /// 전이 요청을 보내기 전에 기다리는 시간. 이 창 안에서 취소하면 Jira에 흔적이 없다.
    ///
    /// `RuleSet`이 아니라 여기 두는 이유: 이 값은 점수에 영향을 주지 않는다.
    /// 사용자가 규칙을 재집계해도 바뀌지 않아야 한다.
    public var transitionUndoWindow: Duration
    /// 동기화가 끝날 때마다 미러의 티켓 전이 후보를 미리 받아 둘 것인가.
    ///
    /// 끄는 쪽은 테스트다 — 응답을 큐로 대는 스텁은 예정에 없던 요청이 다음 답을
    /// 집어삼킨다. 프로덕션 기본은 켬이다: 메뉴를 열 때마다 왕복을 기다리는 지연이
    /// 이 값을 만든 이유다.
    public var prefetchesTransitions: Bool
    /// 미리 받아 둔 전이 후보를 얼마나 믿을 것인가. 이보다 오래된 것은 없는 셈 친다 —
    /// 동기화가 멈춰 있었다면(백오프·절전) 그 사이 워크플로가 바뀌었을 수 있다.
    public var transitionWarmth: Duration
    /// 미리 받을 때 동시에 띄우는 요청 수. 티켓 수만큼 한꺼번에 보내면 429를 부른다.
    public var transitionPrefetchConcurrency: Int

    public init(
        syncInterval: Duration, foregroundCooldown: Duration,
        backoffSteps: [Duration], failuresBeforeSurfacing: Int,
        transitionUndoWindow: Duration,
        prefetchesTransitions: Bool = true,
        transitionWarmth: Duration = .seconds(600),
        transitionPrefetchConcurrency: Int = 3
    ) {
        self.syncInterval = syncInterval
        self.foregroundCooldown = foregroundCooldown
        self.backoffSteps = backoffSteps
        self.failuresBeforeSurfacing = failuresBeforeSurfacing
        self.transitionUndoWindow = transitionUndoWindow
        self.prefetchesTransitions = prefetchesTransitions
        self.transitionWarmth = transitionWarmth
        self.transitionPrefetchConcurrency = max(transitionPrefetchConcurrency, 1)
    }

    public static let `default` = AppSettings(
        syncInterval: .seconds(300),
        foregroundCooldown: .seconds(30),
        backoffSteps: [.seconds(5), .seconds(30), .seconds(120), .seconds(600)],
        failuresBeforeSurfacing: 3,
        transitionUndoWindow: .seconds(5)
    )

    /// 연속 실패 횟수에 해당하는 대기 시간. 0이면 대기 없음, 단계를 넘으면 마지막 값에 머문다.
    public func backoffDelay(afterConsecutiveFailures failures: Int) -> Duration {
        guard failures > 0, !backoffSteps.isEmpty else { return .zero }
        let index = min(failures - 1, backoffSteps.count - 1)
        return backoffSteps[index]
    }
}
