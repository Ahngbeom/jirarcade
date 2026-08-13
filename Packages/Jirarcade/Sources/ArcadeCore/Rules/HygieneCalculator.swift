import Foundation

/// 위생 점수를 올리기 위한 다음 한 걸음. 문자열이 아니라 구조화된 값으로 돌려주고
/// 문장으로 만드는 일은 UI가 한다(ArcadeCore는 화면을 모른다).
public enum HygieneNextStep: Sendable, Equatable {
    case reduceWIP(to: Int, gain: Int)
    case touchZombies(count: Int, gain: Int)
    case resolveGhosts(count: Int, gain: Int)
}

public struct HygieneReport: Sendable, Equatable {
    public let score: Int
    /// 마감 방어 지표. 마감이 지난 미완료 티켓 1건마다 1씩 깎이며 0 아래로 내려가지 않는다.
    public let hp: Int
    public let wipCount: Int
    public let wipPenalty: Int
    public let zombieCount: Int
    public let zombiePenalty: Int
    public let ghostCount: Int
    public let ghostPenalty: Int
    public let nextStep: HygieneNextStep?
}

public struct HygieneCalculator: Sendable {
    private let rules: RuleSet
    private let workflow: WorkflowMap
    private let calendar: Calendar

    public init(rules: RuleSet, workflow: WorkflowMap, calendar: Calendar) {
        self.rules = rules
        self.workflow = workflow
        self.calendar = calendar
    }

    public func evaluate(_ issues: [ObservedIssue], now: Date) -> HygieneReport {
        let staged = issues.compactMap { issue -> (ObservedIssue, Stage)? in
            guard let stage = workflow.stage(for: issue.statusName) else { return nil }
            return (issue, stage)
        }

        let active = staged.filter { $0.1 == .active }
        let wipCount = active.count
        let wipPenalty = max(0, wipCount - rules.wipLimit) * rules.wipPenalty

        let zombieCutoff = now.addingTimeInterval(-Double(rules.zombieDays) * 86_400)
        let zombieCount = active.filter { $0.0.jiraUpdatedAt <= zombieCutoff }.count
        let zombiePenalty = zombieCount * rules.zombiePenalty

        // 마감 당일은 아직 유령이 아니다. 로컬 달력의 날짜 단위로 비교한다(스펙 §8.6).
        let ghostCount = staged.filter { pair in
            guard pair.1 != .done, let due = pair.0.dueDate else { return false }
            return DueDate.isOverdue(due, now: now, calendar: calendar)
        }.count
        let ghostPenalty = ghostCount * rules.ghostPenalty

        let score = max(0, rules.hygieneMaxScore - wipPenalty - zombiePenalty - ghostPenalty)

        var candidates: [(Int, HygieneNextStep)] = []
        if wipPenalty > 0 {
            candidates.append((wipPenalty, .reduceWIP(to: rules.wipLimit, gain: wipPenalty)))
        }
        if zombiePenalty > 0 {
            candidates.append((zombiePenalty, .touchZombies(count: zombieCount, gain: zombiePenalty)))
        }
        if ghostPenalty > 0 {
            candidates.append((ghostPenalty, .resolveGhosts(count: ghostCount, gain: ghostPenalty)))
        }

        return HygieneReport(
            score: score,
            hp: max(0, rules.maxHP - min(ghostCount, rules.maxHP)),
            wipCount: wipCount, wipPenalty: wipPenalty,
            zombieCount: zombieCount, zombiePenalty: zombiePenalty,
            ghostCount: ghostCount, ghostPenalty: ghostPenalty,
            nextStep: candidates.max(by: { $0.0 < $1.0 })?.1
        )
    }
}
