import Foundation

/// 이벤트 한 건의 기본 XP를 계산한다. 중복·상한·되돌림 같은 전체 맥락 조정은 AbuseGuard가 맡는다.
public struct XpAwarder: Sendable {
    private let rules: RuleSet
    private let workflow: WorkflowMap
    private let calendar: Calendar
    private let classifier: StagnationClassifier
    private let myAccountId: String?

    public init(rules: RuleSet, workflow: WorkflowMap, myAccountId: String? = nil, calendar: Calendar) {
        self.rules = rules
        self.workflow = workflow
        self.myAccountId = myAccountId
        self.calendar = calendar
        self.classifier = StagnationClassifier(rules: rules)
    }

    /// `issue`가 nil이면 미러에서 사라진 티켓이다. 정체 기준선은 이벤트가 들고 있으므로
    /// 채점에 지장이 없고, 마감 보너스만 판정할 수 없어 생략된다.
    public func baseXP(
        for event: DomainEvent,
        issue: ObservedIssue?,
        statusEnteredAt: Date?,
        now: Date
    ) -> Int {
        // 실행자 필터. 남이 옮긴 전이는 0점이다(스펙 §4.2).
        //
        // myAccountId가 nil이면 필터를 건너뛴다 — "내가 누군지 모른다"를 "전부 남이 했다"로
        // 해석하면 로그인 전 재집계에서 과거 점수가 통째로 사라진다. 모를 때는 관대한 쪽이 맞다.
        if rules.awardsOnlyOwnTransitions,
           let myAccountId,
           let actor = event.actorAccountId,
           actor != myAccountId {
            return 0
        }

        switch event.kind {
        case .appeared, .vanished, .dueDateChanged:
            return 0
        case .touched:
            return wakeXP(event: event, issue: issue, statusEnteredAt: statusEnteredAt, now: now)
        case .statusChanged:
            return transitionXP(event: event, issue: issue, statusEnteredAt: statusEnteredAt, now: now)
        }
    }

    /// 정체 기준선은 세 단계로 내려간다.
    ///
    /// 1. `statusEnteredAt` — 우리 이벤트 로그에서 재구성한 실측값 (스펙 §5.2 1단)
    /// 2. `event.priorUpdatedAt` — 이 변화 **직전** 미러의 `jiraUpdatedAt` (스펙 §5.2 2단 근사)
    /// 3. `issue.jiraUpdatedAt` — 기준선 없이 기록된 옛 이벤트를 위한 최후 폴백
    ///
    /// 3번은 재집계 직전에 갱신되므로 정체를 거의 항상 0으로 만든다. 2번이 있는 한 쓰이지 않는다.
    private func wakeXP(
        event: DomainEvent, issue: ObservedIssue?, statusEnteredAt: Date?, now: Date
    ) -> Int {
        let baseline = event.priorUpdatedAt ?? issue?.jiraUpdatedAt ?? now
        let elapsed = classifier.daysStagnant(
            statusEnteredAt: statusEnteredAt,
            jiraUpdatedAt: baseline,
            now: now
        )
        let multiplier = min(1 + Double(elapsed) / rules.wakeDivisorDays, rules.wakeMaxMultiplier)
        return Int((Double(rules.wakeBaseXP) * multiplier).rounded())
    }

    private func transitionXP(
        event: DomainEvent, issue: ObservedIssue?, statusEnteredAt: Date?, now: Date
    ) -> Int {
        guard
            let from = event.fromStatus.flatMap({ workflow.stage(for: $0) }),
            let to = event.toStatus.flatMap({ workflow.stage(for: $0) })
        else { return 0 }

        guard to.order > from.order else { return 0 }   // 후퇴·수평 이동은 0점(감점 아님)

        let wake = wakeXP(event: event, issue: issue, statusEnteredAt: statusEnteredAt, now: now)
        var total = Int((Double(wake) * rules.forwardMultiplier).rounded())

        // 마감일은 **이벤트가 관측 시점에 실어둔 값**을 쓴다. 미러를 보면 티켓이 조회 결과에서
        // 사라진 뒤 재집계할 때 보너스가 증발한다 — 준 XP를 도로 뺏게 된다.
        // 여유일은 로컬 달력의 날짜 차이로 센다(스펙 §8.6). 마감 당일 완료는 여유 0일이다.
        if to == .done, let due = event.dueDateAtObservation {
            let spareDays = DueDate.daysRemaining(until: due, from: now, calendar: calendar)
            if spareDays > 0 {
                total += min(spareDays * rules.dueBonusPerDay, rules.dueBonusCap)
            }
        }
        return total
    }
}
