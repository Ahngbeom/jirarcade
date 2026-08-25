import Testing
import Foundation
@testable import ArcadeCore

private var utc: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private var utcCalendar: Calendar { utc }

private func makeTransition(key: String, at when: Date) -> DomainEvent {
    DomainEvent(
        issueKey: key, kind: .statusChanged,
        fromStatus: "To Do", toStatus: "In Progress",
        observedAt: when, actorAccountId: "acc-me",
        priorUpdatedAt: when.addingTimeInterval(-days(21))
    )
}

private let now = iso("2026-08-20T00:00:00Z")

private func sampleEvents() -> [DomainEvent] {
    [
        DomainEvent(issueKey: "DEMO-1", kind: .appeared, fromStatus: nil, toStatus: "To Do",
                    observedAt: iso("2026-08-10T09:00:00Z"), actorAccountId: "acc-me"),
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "To Do", toStatus: "In Progress",
                    observedAt: iso("2026-08-11T09:00:00Z"), actorAccountId: "acc-me"),
        DomainEvent(issueKey: "DEMO-2", kind: .touched, fromStatus: nil, toStatus: nil,
                    observedAt: iso("2026-08-12T09:00:00Z"), actorAccountId: "acc-me"),
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "In Progress", toStatus: "In Review",
                    observedAt: iso("2026-08-13T09:00:00Z"), actorAccountId: "acc-me"),
    ]
}

private func sampleIssues() -> [String: ObservedIssue] {
    [
        "DEMO-1": issue(key: "DEMO-1", status: "In Review", updated: iso("2026-08-13T09:00:00Z")),
        "DEMO-2": issue(key: "DEMO-2", status: "Verifying", updated: iso("2026-08-12T09:00:00Z")),
    ]
}

/// 스펙 §4.2의 중심 약속: **이벤트 XP는 (이벤트 로그, RuleSet)만의 함수다.**
///
/// 미러의 `jiraUpdatedAt`은 재집계 **직전에** 최신값으로 덮이므로, 채점이 이 값을 보면
/// 정체 기준선이 파괴된다. `recomputeIsIdempotent`는 같은 미러를 두 번 넘기므로
/// 이 성질을 잡지 못했다 — 그래서 46일 방치 티켓이 60 XP를 받는 결함이 통과했다.
///
/// 위생 데일리 보너스(§5.3)는 정의상 **현재** 미러의 함수이므로 이 불변식 밖에 있다.
/// 그래서 `totalXP`가 아니라 `totalXP - hygieneBonusXP`로 비교한다.
///
/// 픽스처는 정체 기준선(`priorUpdatedAt`)과 마감 보너스(`dueDateAtObservation`)를 **둘 다**
/// 밟는다. 앞선 수정에서 마감일이 빠졌을 때, 전이가 `.done`이 아닌 픽스처만 있었던 탓에
/// 이 테스트가 통과하면서도 마감 보너스는 미러에 의존한 채로 남았다.
@Test func sameEventLogScoresTheSameRegardlessOfTheMirror() throws {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)

    // 46일 방치된 DEMO-1을 깨우고, DEMO-2를 마감 8일 전에 완료한다.
    let wokeAt = iso("2026-08-13T09:00:00Z")
    let events = [
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "In Progress",
                    toStatus: "In Review", observedAt: wokeAt, actorAccountId: "acc-me",
                    priorUpdatedAt: wokeAt.addingTimeInterval(-days(46))),
        DomainEvent(issueKey: "DEMO-2", kind: .statusChanged, fromStatus: "Verifying",
                    toStatus: "Done", observedAt: wokeAt, actorAccountId: "acc-me",
                    priorUpdatedAt: wokeAt.addingTimeInterval(-days(10)),
                    dueDateAtObservation: iso("2026-08-21T00:00:00Z")),
    ]

    // 미러 A: 아직 옛 값 + 마감일 보존. 미러 B: 갱신되고 마감일이 지워짐.
    // 미러 C: 완료된 티켓이 JQL에서 빠져 통째로 사라짐 — 실제로 다음 폴링에서 벌어지는 일.
    let staleMirror = [
        "DEMO-1": issue(key: "DEMO-1", status: "In Review",
                       updated: wokeAt.addingTimeInterval(-days(46))),
        "DEMO-2": issue(key: "DEMO-2", status: "Done", due: iso("2026-08-21T00:00:00Z"),
                       updated: wokeAt.addingTimeInterval(-days(10))),
    ]
    let freshMirror = [
        "DEMO-1": issue(key: "DEMO-1", status: "In Review", updated: wokeAt),
        "DEMO-2": issue(key: "DEMO-2", status: "Done", due: nil, updated: wokeAt),
    ]

    let a = engine.recompute(events: events, issues: staleMirror, now: now)
    let b = engine.recompute(events: events, issues: freshMirror, now: now)
    let c = engine.recompute(events: events, issues: [:], now: now)

    #expect(a.scored.map(\.xp) == b.scored.map(\.xp))
    #expect(a.scored.map(\.xp) == c.scored.map(\.xp))
    #expect(eventXP(a) == eventXP(b))
    #expect(eventXP(a) == eventXP(c))

    // 픽스처가 정말 마감 보너스 경로를 밟는지 확인한다. 밟지 않으면 이 테스트는
    // 통과하면서도 아무것도 보증하지 않는다 — 정확히 앞선 수정이 놓친 함정이다.
    let completion = try #require(a.scored.first { $0.event.issueKey == "DEMO-2" })
    let withoutDueDate = engine.recompute(
        events: events.map {
            $0.issueKey == "DEMO-2"
                ? DomainEvent(issueKey: "DEMO-2", kind: .statusChanged, fromStatus: "Verifying",
                              toStatus: "Done", observedAt: wokeAt, actorAccountId: "acc-me",
                              priorUpdatedAt: wokeAt.addingTimeInterval(-days(10)),
                              dueDateAtObservation: nil)
                : $0
        },
        issues: staleMirror, now: now
    )
    let plain = try #require(withoutDueDate.scored.first { $0.event.issueKey == "DEMO-2" })
    #expect(completion.xp > plain.xp, "마감 보너스가 실제로 붙어야 픽스처가 의미를 갖는다")
}

private func eventXP(_ result: (scored: [ScoredEvent], summary: PlayerSummary)) -> Int {
    result.summary.totalXP - result.summary.hygieneBonusXP
}

/// 스펙 §5.2: 45일↑ 방치 티켓의 깨우기 XP는 상한 160, 전진 전이면 × 1.5 = 240.
/// 여기에 스펙 §5.4의 연속 보너스가 곱해진다 — 체크인 1일차라 × 1.05.
@Test func wakingA46DayIdleTicketPaysTheRaidTierAward() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    let wokeAt = iso("2026-08-13T09:00:00Z")
    let events = [
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "In Progress",
                    toStatus: "In Review", observedAt: wokeAt, actorAccountId: "acc-me",
                    priorUpdatedAt: wokeAt.addingTimeInterval(-days(46))),
    ]
    let mirror = ["DEMO-1": issue(key: "DEMO-1", status: "In Review", updated: wokeAt)]
    let result = engine.recompute(events: events, issues: mirror, now: now)
    #expect(result.scored[0].xp == 252)   // 160 × 1.5 = 240, × 1.05(연속 1일차)
}

@Test func recomputeIsIdempotent() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    let first = engine.recompute(events: sampleEvents(), issues: sampleIssues(), now: now)
    let second = engine.recompute(events: sampleEvents(), issues: sampleIssues(), now: now)
    #expect(first.scored == second.scored)
    #expect(first.summary == second.summary)
}

/// 규칙을 바꾸면 재집계 결과가 그에 비례해 달라진다.
///
/// "정확히 2배"를 요구하지 않는 이유: XP는 정수이고 `XpAwarder`가 반올림하므로
/// `round(2x) != 2·round(x)`다. 예컨대 정체 2일 이벤트는 base 40에서 `45.71 → 46`,
/// base 80에서 `91.43 → 91`이 되어 이벤트마다 최대 1XP가 어긋난다.
/// 정수 점수 체계에서 완전한 스케일 선형성은 원리적으로 불가능하다.
///
/// 스펙이 요구하는 "규칙 변경 후 재집계 = 새 규칙으로 처음부터 계산"은
/// ScoreEngine이 누적 상태를 갖지 않는 구조 자체로 보장되며,
/// `recomputeIsIdempotent`가 그 성질을 지킨다.
@Test func changingRulesChangesTheResultProportionally() {
    var doubled = RuleSet.default
    doubled.wakeBaseXP = RuleSet.default.wakeBaseXP * 2

    let base = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
        .recompute(events: sampleEvents(), issues: sampleIssues(), now: now)
    let scaled = ScoreEngine(rules: doubled, workflow: demoWorkflow, calendar: utc)
        .recompute(events: sampleEvents(), issues: sampleIssues(), now: now)

    // 위생 데일리 보너스는 wakeBaseXP와 무관한 상수라 비율에서 제외한다.
    #expect(eventXP(base) > 0, "기준 점수가 0이면 비율 검증이 무의미하다")
    #expect(eventXP(scaled) > eventXP(base))

    let ratio = Double(eventXP(scaled)) / Double(eventXP(base))
    #expect(abs(ratio - 2.0) < 0.05, "실제 비율 \(ratio)")
}

/// 규칙 변경이 결과에 실제로 반영되는지를 반올림과 무관하게 확인한다.
/// 값의 크기가 아니라 "달라진다"는 사실 자체를 검증하므로 정수 오차의 영향을 받지 않는다.
@Test func changingRulesActuallyChangesScores() {
    var stricter = RuleSet.default
    stricter.forwardMultiplier = 1.0   // 전진 보너스 제거

    let base = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
        .recompute(events: sampleEvents(), issues: sampleIssues(), now: now)
    let changed = ScoreEngine(rules: stricter, workflow: demoWorkflow, calendar: utc)
        .recompute(events: sampleEvents(), issues: sampleIssues(), now: now)

    #expect(changed.summary.totalXP < base.summary.totalXP)
}

@Test func statusEnteredAtComesFromEarlierEventsNotJiraUpdated() {
    // DEMO-1은 08-11에 "In Progress"으로 들어갔고 08-13에 전이했으므로 정체는 2일이다.
    // jiraUpdatedAt(08-13)으로 근사했다면 정체 0일이 되어 XP가 달라진다.
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    let result = engine.recompute(events: sampleEvents(), issues: sampleIssues(), now: now)
    let transition = result.scored.first {
        $0.event.issueKey == "DEMO-1" && $0.event.toStatus == "In Review"
    }
    // 40 × (1 + 2/14) = 45.71 → 46, × 1.5 = 69
    // touched가 0점이 된 뒤로는 08-12가 체크인 일이 아니므로 연속은 2일차다.
    // × 1.10(연속 2일차) = 75.9 → 76
    #expect(transition?.xp == 76)
}

@Test func summaryLevelMatchesTheCurve() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    let result = engine.recompute(events: sampleEvents(), issues: sampleIssues(), now: now)
    let curve = LevelCurve(rules: .default)
    #expect(result.summary.level == curve.level(forTotalXP: result.summary.totalXP))
}

@Test func emptyHistoryProducesLevelOne() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    let result = engine.recompute(events: [], issues: [:], now: now)
    #expect(result.summary.totalXP == 0)
    #expect(result.summary.level == 1)
    #expect(result.summary.streak.currentStreak == 0)
}

// MARK: - 스펙 §5.6의 3단 파이프라인

/// 같은 기본 XP라도 연속 일수가 쌓이면 그날 XP에 배수가 붙는다(스펙 §5.4).
@Test func streakMultiplierIsAppliedToThatDaysXP() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)

    // 8/12(수)부터 평일 연속으로 같은 크기의 전이를 하나씩 낸다.
    let dayStamps = ["2026-08-12", "2026-08-13", "2026-08-14", "2026-08-17"]
    var events: [DomainEvent] = []
    for (index, day) in dayStamps.enumerated() {
        let at = iso("\(day)T09:00:00Z")
        events.append(DomainEvent(
            issueKey: "DEMO-\(index)", kind: .statusChanged, fromStatus: "To Do",
            toStatus: "In Progress", observedAt: at, actorAccountId: "acc-me",
            priorUpdatedAt: at   // 정체 0일 → 기본 XP는 40 × 1.0 × 1.5 = 60으로 고정
        ))
    }

    let result = engine.recompute(events: events, issues: [:], now: iso("2026-08-17T12:00:00Z"))
    // 60 × 1.05 / 1.10 / 1.15 / 1.20 → 63 / 66 / 69 / 72
    #expect(result.scored.map(\.xp) == [63, 66, 69, 72])
}

/// 연속이 끊기면 배수도 1일차로 돌아간다.
@Test func breakingTheStreakResetsTheMultiplier() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)

    func transition(_ key: String, _ stamp: String) -> DomainEvent {
        let at = iso("\(stamp)T09:00:00Z")
        return DomainEvent(issueKey: key, kind: .statusChanged, fromStatus: "To Do",
                           toStatus: "In Progress", observedAt: at, actorAccountId: "acc-me",
                           priorUpdatedAt: at)
    }

    // 8/12 → 8/13 연속, 이후 평일 3일 결석(동결 1회로도 못 막는다) → 8/19에 1일차로 재시작.
    let events = [transition("DEMO-1", "2026-08-12"),
                  transition("DEMO-2", "2026-08-13"),
                  transition("DEMO-3", "2026-08-19")]
    let result = engine.recompute(events: events, issues: [:], now: iso("2026-08-19T12:00:00Z"))

    #expect(result.scored.map(\.xp) == [63, 66, 63])
    #expect(result.summary.streak.currentStreak == 1)
}

/// 스펙 §5.6: 일일 상한은 **연속 보너스를 적용한 뒤** 걸린다.
/// 순서가 반대라면 상한에 걸린 뒤 배수가 곱해져 1,200을 넘겨 지급된다.
@Test func dailyCapIsAppliedAfterTheStreakMultiplier() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    let day = iso("2026-08-12T09:00:00Z")

    // 정체 200일 전이 20건: 기본 XP 160 × 1.5 = 240씩. 배수 전 합계 4,800.
    let events = (1...20).map { index in
        DomainEvent(issueKey: "DEMO-\(index)", kind: .statusChanged, fromStatus: "In Progress",
                    toStatus: "In Review",
                    observedAt: day.addingTimeInterval(minutes(Double(index))),
                    actorAccountId: "acc-me",
                    priorUpdatedAt: day.addingTimeInterval(-days(200)))
    }

    let result = engine.recompute(events: events, issues: [:], now: day)
    let total = result.scored.reduce(0) { $0 + $1.xp }
    #expect(total == 1_200, "배수를 곱한 뒤에도 상한을 넘지 않는다")
}

// MARK: - 스펙 §5.3 위생 데일리 보너스

private func mirror(activeCount: Int, at now: Date) -> [String: ObservedIssue] {
    var result: [String: ObservedIssue] = [:]
    for index in 1...activeCount {
        let key = "DEMO-\(index)"
        result[key] = issue(key: key, status: "In Progress", updated: now.addingTimeInterval(-days(1)))
    }
    return result
}

@Test func hygieneBonusIsGrantedWhenTodaysScoreMeetsTheThreshold() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    // In Progress 7건 → (7 - 5) × 8 = 16 감점 → 84점, 기준 80 이상.
    let result = engine.recompute(events: [], issues: mirror(activeCount: 7, at: now), now: now)
    #expect(result.summary.hygieneBonusXP == 50)
    #expect(result.summary.totalXP == 50)
}

@Test func hygieneBonusIsWithheldJustBelowTheThreshold() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    // In Progress 8건 → 24 감점 → 76점, 기준 미달.
    let result = engine.recompute(events: [], issues: mirror(activeCount: 8, at: now), now: now)
    #expect(result.summary.hygieneBonusXP == 0)
    #expect(result.summary.totalXP == 0)
}

/// 경계값(정확히 80점)은 포함이다.
@Test func hygieneBonusIsGrantedExactlyAtTheThreshold() {
    var rules = RuleSet.default
    rules.wipLimit = 5
    rules.wipPenalty = 10   // In Progress 7건 → 20 감점 → 정확히 80점
    let engine = ScoreEngine(rules: rules, workflow: demoWorkflow, calendar: utc)
    let result = engine.recompute(events: [], issues: mirror(activeCount: 7, at: now), now: now)
    #expect(result.summary.hygieneBonusXP == rules.hygieneBonusXP)
}

/// 스펙 §5.6의 일일 상한은 이벤트 XP와 위생 보너스가 **함께** 나눠 쓴다.
/// 상한을 이미 채운 날에는 보너스가 붙지 않는다.
@Test func hygieneBonusSharesTheDailyCapWithEvents() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    let today = calendarDay(now)

    // 오늘 하루에 상한을 넘기고도 남을 전이를 쌓는다(각 240, 20건).
    let events = (1...20).map { index in
        DomainEvent(issueKey: "DEMO-\(index)", kind: .statusChanged, fromStatus: "In Progress",
                    toStatus: "In Review",
                    observedAt: today.addingTimeInterval(minutes(Double(index))),
                    actorAccountId: "acc-me",
                    priorUpdatedAt: today.addingTimeInterval(-days(200)))
    }

    // 위생은 기준을 넘는 상태(In Progress 7건 → 84점)로 둔다.
    let result = engine.recompute(events: events, issues: mirror(activeCount: 7, at: now), now: now)

    #expect(result.scored.reduce(0) { $0 + $1.xp } == RuleSet.default.dailyXPCap)
    #expect(result.summary.hygieneBonusXP == 0, "이벤트가 상한을 다 썼으면 보너스 몫이 없다")
    #expect(result.summary.totalXP == RuleSet.default.dailyXPCap)
}

/// 상한에 조금 남았으면 그만큼만 지급한다(부분 지급).
@Test func hygieneBonusIsTruncatedToTheRemainingAllowance() {
    var rules = RuleSet.default
    rules.dailyXPCap = 270   // 전이 1건(252) 뒤 18만 남는다
    let engine = ScoreEngine(rules: rules, workflow: demoWorkflow, calendar: utc)
    let today = calendarDay(now)

    let events = [
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "In Progress",
                    toStatus: "In Review", observedAt: today.addingTimeInterval(hours(9)),
                    actorAccountId: "acc-me",
                    priorUpdatedAt: today.addingTimeInterval(-days(200))),
    ]
    let result = engine.recompute(events: events, issues: mirror(activeCount: 7, at: now), now: now)

    #expect(result.scored[0].xp == 252)
    #expect(result.summary.hygieneBonusXP == 18)
    #expect(result.summary.totalXP == rules.dailyXPCap)
}

private func calendarDay(_ date: Date) -> Date {
    utc.startOfDay(for: date)
}

/// 미러가 비면 위생은 "완벽"이 아니라 판정 불가다.
@Test func hygieneBonusNeedsSomethingToBeHygienicAbout() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    #expect(engine.recompute(events: [], issues: [:], now: now).summary.hygieneBonusXP == 0)
}

@Test func eventsAreProcessedInChronologicalOrderRegardlessOfInputOrder() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    let forward = engine.recompute(events: sampleEvents(), issues: sampleIssues(), now: now)
    let reversed = engine.recompute(events: sampleEvents().reversed(), issues: sampleIssues(), now: now)
    #expect(forward.summary.totalXP == reversed.summary.totalXP)
}

/// 시즌은 이벤트 로그를 기간으로 자른 재집계일 뿐이다. 이벤트가 원본이고 점수가 파생이라
/// 필터 한 줄로 끝난다 — XP를 누적 저장했다면 "최근 30일 XP"를 따로 관리해야 했다(스펙 §6).
@MainActor
@Test func seasonScoreCountsOnlyRecentEvents() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utcCalendar,
                             myAccountId: "acc-me")
    let now = iso("2026-08-13T00:00:00Z")
    let events = [
        makeTransition(key: "MPT-1", at: iso("2026-01-01T00:00:00Z")),   // 시즌 밖
        makeTransition(key: "MPT-2", at: iso("2026-08-10T00:00:00Z")),   // 시즌 안
    ]

    let lifetime = engine.recompute(events: events, issues: [:], now: now)
    let season = engine.recompute(events: events, issues: [:], now: now,
                                  since: iso("2026-07-14T00:00:00Z"))

    #expect(season.summary.totalXP < lifetime.summary.totalXP)
    #expect(season.scored.count == 1)
    #expect(lifetime.scored.count == 2)
}

/// 경계에 정확히 걸린 이벤트는 시즌에 포함된다(>= since).
@MainActor
@Test func eventExactlyAtSeasonStartIsIncluded() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utcCalendar,
                             myAccountId: "acc-me")
    let boundary = iso("2026-07-14T00:00:00Z")
    let result = engine.recompute(
        events: [makeTransition(key: "MPT-1", at: boundary)],
        issues: [:], now: iso("2026-08-13T00:00:00Z"), since: boundary
    )
    #expect(result.scored.count == 1)
}

/// since를 주지 않으면 기존 동작과 완전히 같다 — 기존 호출부가 영향을 받지 않는다.
@MainActor
@Test func omittingSinceMatchesLifetime() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utcCalendar,
                             myAccountId: "acc-me")
    let now = iso("2026-08-13T00:00:00Z")
    let events = [makeTransition(key: "MPT-1", at: iso("2026-01-01T00:00:00Z"))]
    let a = engine.recompute(events: events, issues: [:], now: now)
    let b = engine.recompute(events: events, issues: [:], now: now, since: nil)
    #expect(a.summary == b.summary)
}

/// touched만 있는 날은 체크인이 아니다. 체크인은 XP가 붙은 날의 집합이고,
/// touched가 0점이 된 뒤로는 그런 날이 점수에도 연속 기록에도 남지 않는다.
@Test func aDayWithOnlyTouchedEventsIsNotACheckIn() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow,
                             calendar: utc, myAccountId: "acc-me")
    let events = [
        DomainEvent(issueKey: "DEMO-1", kind: .touched, fromStatus: nil, toStatus: nil,
                    observedAt: iso("2026-08-20T09:00:00Z"), actorAccountId: "acc-me",
                    priorUpdatedAt: iso("2026-05-01T09:00:00Z"), dueDateAtObservation: nil)
    ]

    let (_, summary) = engine.recompute(events: events, issues: [:],
                                        now: iso("2026-08-24T09:00:00Z"))

    #expect(summary.totalXP == 0)
    #expect(summary.streak.currentStreak == 0)
}

// MARK: - 정체 기준선을 밀지 않는 이벤트

/// 이 절의 픽스처는 하나의 티켓 위에 세 가지를 겹쳐 둔다: 긴 정체, 창 안의 되돌림 쌍,
/// 그리고 그 뒤의 전진 전이. **마지막 전이가 받는 XP가 곧 기준선의 위치를 말한다** —
/// 24일 정체를 깬 전이와 3일 정체를 깬 전이는 배수가 다르기 때문이다.
///
/// 보드가 그리는 정체일(`StatusTimeline.latestStatusEntry`)과 채점이 쓰는 시점별 기준선은
/// 같은 규칙이어야 한다. 시간축 쪽은 `StatusTimelineTests`가 지키고, 이 절이 채점 쪽을 지킨다.
private let baselineStart = iso("2026-07-01T09:00:00Z")

private func transition(
    _ key: String = "DEMO-1", from: String, to: String, at stamp: String,
    priorUpdatedAt: Date? = nil
) -> DomainEvent {
    DomainEvent(issueKey: key, kind: .statusChanged, fromStatus: from, toStatus: to,
                observedAt: iso(stamp), actorAccountId: "acc-me",
                priorUpdatedAt: priorUpdatedAt)
}

/// 07-01에 In Progress로 들어가고, 07-21에 3분짜리 오조작을 하고, 07-25에 진짜로 옮긴다.
private func revertPairFixture() -> (opening: DomainEvent, pair: [DomainEvent], forward: DomainEvent) {
    (
        opening: transition(from: "To Do", to: "In Progress", at: "2026-07-01T09:00:00Z",
                            priorUpdatedAt: baselineStart),
        pair: [
            transition(from: "In Progress", to: "In Review", at: "2026-07-21T09:00:00Z"),
            transition(from: "In Review", to: "In Progress", at: "2026-07-21T09:03:00Z"),
        ],
        forward: transition(from: "In Progress", to: "In Review", at: "2026-07-25T09:00:00Z")
    )
}

private func scoreOfForward(_ events: [DomainEvent]) throws -> Int {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    let result = engine.recompute(events: events, issues: [:], now: now)
    let forward = try #require(result.scored.first {
        $0.event.observedAt == iso("2026-07-25T09:00:00Z")
    })
    return forward.xp
}

/// **되돌림 쌍은 채점의 정체 기준선도 밀지 않는다.** 3분 만에 되돌린 오조작이 24일 정체를
/// 지우면, 보드는 24일을 그리는데 `wakeXP`는 "방금 옮긴 것"으로 채점해 두 층이 갈린다.
@Test func aRevertPairDoesNotMoveTheScoringBaseline() throws {
    let fixture = revertPairFixture()

    let withPair = try scoreOfForward([fixture.opening] + fixture.pair + [fixture.forward])
    let withoutPair = try scoreOfForward([fixture.opening, fixture.forward])

    #expect(withPair == withoutPair)
    // 정체 24일 → 40 × (1 + 24/14) = 108.57 → 109, × 1.5 = 163.5 → 164, × 1.05(연속 1일차) = 172.2 → 172.
    // 값을 못박아 두는 이유: 두 실행이 **똑같이 틀려도** 위의 등식은 초록이다.
    #expect(withPair == 172)
}

/// **인덱스는 넘긴 배열 기준이다.** `recompute`는 입력을 `ordered`로 정렬해 순회하므로
/// `RevertDetector`에도 `ordered`를 넘겨야 한다. `events`를 넘기면 컴파일되고 범위 안에도
/// 있지만 **엉뚱한 위치를 건너뛴다** — 그러면 실제로는 되돌림이 아닌 전이가 기준선을 밀고,
/// 되돌림 쌍이 민 기준선은 남는다.
///
/// 픽스처는 정렬 전후 순서가 **다르다**. 같으면 이 테스트는 아무것도 증명하지 않는다.
@Test func theRevertSkipFollowsTheOrderTheLoopWalks() throws {
    let fixture = revertPairFixture()
    let chronological = [fixture.opening] + fixture.pair + [fixture.forward]
    let shuffled = [fixture.forward, fixture.opening] + fixture.pair

    #expect(shuffled.map(\.observedAt) != chronological.map(\.observedAt),
            "정렬 전후가 같은 픽스처로는 순서 의존을 잡을 수 없다")

    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    let ordered = engine.recompute(events: chronological, issues: [:], now: now)
    let jumbled = engine.recompute(events: shuffled, issues: [:], now: now)

    #expect(ordered.scored.map(\.xp) == jumbled.scored.map(\.xp))
    #expect(ordered.summary.totalXP == jumbled.summary.totalXP)
}

/// **같은 상태로의 전환(no-op)도 채점의 기준선을 밀지 않는다.** 백필은 라이브 동기화와
/// 달리 이런 이벤트를 거르지 않아 실제 로그에 남는다. 밀게 두면 아무 데도 가지 않은
/// 티켓의 정체가 채점에서만 리셋된다.
@Test func aNoOpTransitionDoesNotMoveTheScoringBaseline() throws {
    let opening = transition(from: "To Do", to: "In Progress", at: "2026-07-01T09:00:00Z",
                             priorUpdatedAt: baselineStart)
    let noOp = transition(from: "In Progress", to: "In Progress", at: "2026-07-21T09:00:00Z")
    let forward = transition(from: "In Progress", to: "In Review", at: "2026-07-25T09:00:00Z")

    let withNoOp = try scoreOfForward([opening, noOp, forward])
    let withoutNoOp = try scoreOfForward([opening, forward])

    #expect(withNoOp == withoutNoOp)
    #expect(withNoOp == 172)
}
