import Foundation

public struct PlayerSummary: Sendable, Equatable {
    public let totalXP: Int
    public let level: Int
    public let xpIntoLevel: Int
    public let xpForNextLevel: Int
    public let streak: StreakState
    /// 오늘 위생 점수가 기준을 넘어 지급된 데일리 보너스(스펙 §5.3). 없으면 0.
    /// `totalXP`에 이미 포함되어 있으며, UI가 "어디서 왔는지"를 보여줄 수 있게 따로 노출한다.
    public let hygieneBonusXP: Int
}

/// 이벤트 로그 전체를 다시 읽어 점수를 계산한다.
/// 누적 갱신을 하지 않고 항상 처음부터 계산하므로, 규칙을 바꿔도 결과가 일관된다.
public struct ScoreEngine: Sendable {
    private let rules: RuleSet
    private let workflow: WorkflowMap
    private let calendar: Calendar
    private let awarder: XpAwarder
    private let abuseGuard: AbuseGuard
    private let curve: LevelCurve
    private let streaks: StreakCalculator
    private let hygiene: HygieneCalculator

    public init(rules: RuleSet, workflow: WorkflowMap, calendar: Calendar,
                myAccountId: String? = nil) {
        self.rules = rules
        self.workflow = workflow
        self.calendar = calendar
        self.awarder = XpAwarder(rules: rules, workflow: workflow, myAccountId: myAccountId,
                                 calendar: calendar)
        self.abuseGuard = AbuseGuard(rules: rules, calendar: calendar)
        self.curve = LevelCurve(rules: rules)
        self.streaks = StreakCalculator(rules: rules, calendar: calendar)
        self.hygiene = HygieneCalculator(rules: rules, workflow: workflow, calendar: calendar)
    }

    /// 스펙 §5.6이 정한 3단 파이프라인을 순서대로 적용한다.
    /// 기본 XP → (무효화) → 연속 보너스 배수 → 일일 상한 → 위생 데일리 보너스.
    ///
    /// - Parameter now: **오늘**의 기준. 이벤트 채점은 각 이벤트의 `observedAt`으로 하지만,
    ///   위생 데일리 보너스(스펙 §5.3)는 미러의 현재 상태를 이 시각 기준으로 판정한다.
    ///   미러에는 과거 상태가 없으므로 위생 보너스는 오늘 하루분만 계산할 수 있다.
    /// - Parameter since: 이 시각 이후의 이벤트만 집계한다. nil이면 전체(통산).
    ///   시즌 XP 바가 이 파라미터로 계산된다(스펙 §6).
    ///
    ///   **시즌은 범위만 자르고 채점 규칙은 바꾸지 않는다.** 그래서 파이프라인 전체를
    ///   통산 로그로 끝낸 **뒤에** 잘라낸다. 어느 단계든 잘라낸 뒤에 계산하면 같은 이벤트가
    ///   통산과 시즌에서 다른 XP를 받는다 — 사용자는 HUD의 시즌 레벨과 프로필의 통산 레벨을
    ///   나란히 보므로 어긋나면 즉시 드러난다.
    ///   · statusEnteredAt: 잘라내면 시즌 첫 전이의 정체 기준선이 사라진다.
    ///   · 연속 배수: 잘라내면 시즌 시작 직후 이벤트가 연속 1일부터 다시 센 배수를 받는다.
    ///   · 무효화·일일 상한: 잘라내면 시즌 밖 짝을 못 봐서 왕복·중복이 그대로 지급된다.
    public func recompute(
        events: [DomainEvent],
        issues: [String: ObservedIssue],
        now: Date,
        since: Date? = nil
    ) -> (scored: [ScoredEvent], summary: PlayerSummary) {
        let ordered = events.sorted { $0.observedAt < $1.observedAt }

        // 시간축과 같은 판정을 쓴다 — 보드가 쓰는 최종값과 채점이 쓰는 시점별 값이
        // 다른 규칙으로 갈리면 같은 티켓의 정체일이 화면과 점수에서 달라진다.
        //
        // `ordered`를 넘긴다. 인덱스는 넘긴 배열 기준이고 아래 순회가 그 배열을 돈다.
        let reverted = RevertDetector.revertedIndices(
            in: ordered, windowMinutes: rules.revertWindowMinutes
        )

        // 각 티켓이 현재 상태에 들어간 시각을 이벤트 순회로 재구성한다.
        var statusEnteredAt: [String: Date] = [:]
        var scored: [ScoredEvent] = []
        scored.reserveCapacity(ordered.count)

        for (index, event) in ordered.enumerated() {
            let xp = awarder.baseXP(
                for: event,
                issue: issues[event.issueKey],
                statusEnteredAt: statusEnteredAt[event.issueKey],
                now: event.observedAt
            )
            scored.append(ScoredEvent(event: event, xp: xp))

            // 갱신 규칙은 StatusTimeline이 유일하게 정의한다. 여기에 규칙을 복사해 두면
            // 보드가 쓰는 최종값과 채점이 쓰는 시점별 값이 서로 다른 규칙으로 갈릴 수 있다.
            guard reverted.contains(index) == false else { continue }
            // 백필의 no-op 전환(fromStatus == toStatus)도 기준선을 밀지 않는다 —
            // `StatusTimeline.latestStatusEntry`와 같은 판정이다.
            guard StatusTimeline.isNoOpTransition(event) == false else { continue }
            StatusTimeline.apply(event, to: &statusEnteredAt)
        }

        let voided = abuseGuard.applyVoids(to: scored)

        // 연속 기록은 체크인한 날만 이어진다. 그날의 연속 일수가 그날 XP의 배수를 정한다.
        var streak = StreakState.initial
        var multiplierByDay: [Date: Double] = [:]
        for day in checkInDays(from: voided) {
            streak = streaks.checkIn(streak, at: day)
            multiplierByDay[day] = streaks.multiplier(forStreak: streak.currentStreak)
        }

        var boosted = voided
        for index in boosted.indices where boosted[index].xp > 0 {
            let day = calendar.startOfDay(for: boosted[index].event.observedAt)
            guard let multiplier = multiplierByDay[day] else { continue }
            boosted[index].xp = Int((Double(boosted[index].xp) * multiplier).rounded())
        }

        let capped = abuseGuard.applyDailyCap(to: boosted)

        // 마지막에 한 번만 자른다. 여기까지의 XP는 통산과 시즌에서 같은 값이다.
        let adjusted = since.map { start in
            capped.filter { $0.event.observedAt >= start }
        } ?? capped

        let bonus = hygieneDailyBonus(issues: issues, scored: adjusted, now: now)
        let totalXP = adjusted.reduce(0) { $0 + $1.xp } + bonus

        let progress = curve.progress(forTotalXP: totalXP)
        let summary = PlayerSummary(
            totalXP: totalXP,
            level: progress.level,
            xpIntoLevel: progress.xpIntoLevel,
            xpForNextLevel: progress.xpForNextLevel,
            streak: streak,
            hygieneBonusXP: bonus
        )
        return (adjusted, summary)
    }

    /// 스펙 §5.3: 위생 점수가 기준 이상인 날에 데일리 보너스를 준다.
    ///
    /// 미러는 **현재 상태만** 담으므로 과거 어느 날의 위생 점수도 복원할 수 없다.
    /// 따라서 오늘 하루분만 판정한다 — 지난날의 보너스는 소급되지 않는다.
    /// 일일 상한은 이벤트 XP와 보너스가 함께 나눠 쓴다(스펙 §5.6).
    private func hygieneDailyBonus(
        issues: [String: ObservedIssue], scored: [ScoredEvent], now: Date
    ) -> Int {
        // 티켓이 하나도 없으면 위생은 "완벽"이 아니라 정의되지 않는다. 감점할 대상이
        // 없다는 이유로 보너스를 주면 아무것도 관측하지 않은 상태에 XP가 붙는다.
        guard !issues.isEmpty else { return 0 }

        let report = hygiene.evaluate(Array(issues.values), now: now)
        guard report.score >= rules.hygieneBonusThreshold else { return 0 }

        let today = calendar.startOfDay(for: now)
        let remaining = abuseGuard.remainingDailyAllowance(on: today, after: scored)
        return min(rules.hygieneBonusXP, remaining)
    }

    /// XP가 붙은 이벤트가 하루에 한 건이라도 있으면 그날은 체크인으로 본다.
    private func checkInDays(from scored: [ScoredEvent]) -> [Date] {
        var seen = Set<Date>()
        var result: [Date] = []
        for item in scored where item.xp > 0 {
            let day = calendar.startOfDay(for: item.event.observedAt)
            if seen.insert(day).inserted { result.append(day) }
        }
        return result.sorted()
    }
}
