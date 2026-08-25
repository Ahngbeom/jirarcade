import Foundation
import JiraKit

/// 티켓의 스프린트 이력에서 화면이 쓰는 것만 뽑은 요약.
///
/// **문장을 담지 않는다.** `"A → B"` 같은 표현은 뷰가 만든다 — `DueState`·`HygieneNextStep`과
/// 같은 경계다. `ArcadeCore`가 문자열을 만들면 그 모듈이 화면을 알게 된다.
public struct SprintSummary: Sendable, Equatable {
    /// 거쳐 온 스프린트 수 - 1. 0개나 1개면 0이다.
    public let carryOvers: Int
    /// 가장 이른 스프린트 이름.
    public let firstName: String?
    /// 가장 늦은 스프린트 이름.
    public let latestName: String?

    public init(carryOvers: Int, firstName: String?, latestName: String?) {
        self.carryOvers = carryOvers
        self.firstName = firstName
        self.latestName = latestName
    }

    public static let none = SprintSummary(carryOvers: 0, firstName: nil, latestName: nil)
}

public enum SprintHistory {
    /// 스프린트 배열에서 이월 횟수와 양 끝 이름을 뽑는다.
    ///
    /// **배열은 시간순이 아니다.** 실측에서 `[56, 57, 55, 64, 63, 52, 65, 62, 60, 61, 59, 58, 66]`
    /// 순으로 왔다. `startDate`로 정렬해야 첫·마지막이 맞는다.
    ///
    /// `state`는 구분하지 않는다 — 예정 스프린트에 올라가 있다는 것도 "아직 안 끝났다"는
    /// 같은 이야기다.
    public static func summarize(_ sprints: [JiraSprint]) -> SprintSummary {
        guard !sprints.isEmpty else { return .none }

        // `startDate`가 없는 것은 맨 뒤로 보내되 버리지 않는다 — 그 스프린트에 속했다는
        // 사실은 날짜를 모른다고 사라지지 않으므로 횟수에는 들어가야 한다.
        //
        // 동률을 `id`로 가르는 이유: Swift의 `sorted(by:)`는 안정 정렬이 아니라, 같은 날
        // 시작한 스프린트 둘이 있으면 툴팁의 양 끝이 실행마다 뒤집힌다.
        let ordered = sprints.sorted { left, right in
            switch (left.startDate, right.startDate) {
            case let (l?, r?): return l == r ? left.id < right.id : l < r
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return left.id < right.id
            }
        }

        return SprintSummary(
            carryOvers: ordered.count - 1,
            firstName: displayName(ordered.first?.name),
            latestName: displayName(ordered.last?.name)
        )
    }

    /// 이름을 **모르는** 것과 빈 이름을 같게 다룬다.
    ///
    /// 소비자는 `nil`인지만 보고 그릴지 말지 정한다. 빈 문자열을 그대로 실으면 툴팁이
    /// `" → DEMO 스프린트 (5)"`처럼 앞이 빈 화살표가 되어 화면에 나간다. 여기서 거르면
    /// 뷰는 손대지 않아도 된다 — `ArcadeUI`에는 테스트 타깃이 없으므로 판단을 두지 않는 편이 낫다.
    ///
    /// **횟수에는 영향이 없다.** 이름을 못 읽었다고 그 스프린트를 거친 사실이 사라지지는 않는다.
    private static func displayName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
