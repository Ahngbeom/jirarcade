import Foundation

/// 실행 취소 창 안에서 대기 중인 전이 한 건.
///
/// 값 타입이며 스토어에 쓰지 않는다. 롤백은 이 값을 지우는 것이고, Jira에는 아직
/// 아무것도 보내지 않았으므로 되돌릴 것도 없다.
public struct PendingTransition: Sendable, Equatable {
    public let issueKey: String
    public let transitionId: String
    /// 낙관적으로 그릴 상태명. 보드가 이 값으로 단계를 다시 가른다.
    public let toStatusName: String
    /// 되돌릴 때 쓸 원래 상태명.
    ///
    /// **요청 시점에 붙잡아 둔다.** 실행 시점에 미러를 다시 읽으면 그 사이 동기화가
    /// 미러를 갱신했을 수 있고, 그러면 롤백이 엉뚱한 상태로 되돌린다.
    public let fromStatusName: String
    /// 요청이 나갈 시각. 카드가 남은 시간을 그린다.
    public let firesAt: Date

    public init(
        issueKey: String, transitionId: String, toStatusName: String,
        fromStatusName: String, firesAt: Date
    ) {
        self.issueKey = issueKey
        self.transitionId = transitionId
        self.toStatusName = toStatusName
        self.fromStatusName = fromStatusName
        self.firesAt = firesAt
    }
}
