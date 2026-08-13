import Foundation

public enum StagnationTier: String, Sendable, Comparable, CaseIterable {
    case fresh, stale, boss, raid

    private var rank: Int {
        switch self {
        case .fresh: 0
        case .stale: 1
        case .boss:  2
        case .raid:  3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public struct StagnationClassifier: Sendable {
    private let rules: RuleSet

    public init(rules: RuleSet) {
        self.rules = rules
    }

    /// 관측 이력(statusEnteredAt)이 없으면 근사 기준을 쓴다는 사실을 호출부가 UI에 표시할 수 있게 노출한다.
    public func isApproximate(statusEnteredAt: Date?) -> Bool {
        statusEnteredAt == nil
    }

    public func daysStagnant(statusEnteredAt: Date?, jiraUpdatedAt: Date, now: Date) -> Int {
        let reference = statusEnteredAt ?? jiraUpdatedAt
        let elapsed = now.timeIntervalSince(reference)
        guard elapsed > 0 else { return 0 }
        return Int(elapsed / 86_400)
    }

    public func classify(statusEnteredAt: Date?, jiraUpdatedAt: Date, now: Date) -> StagnationTier {
        let elapsed = daysStagnant(statusEnteredAt: statusEnteredAt, jiraUpdatedAt: jiraUpdatedAt, now: now)
        if elapsed >= rules.raidDays { return .raid }
        if elapsed >= rules.bossDays { return .boss }
        if elapsed >= rules.staleDays { return .stale }
        return .fresh
    }
}
