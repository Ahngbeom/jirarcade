import Testing
import Foundation
@testable import ArcadeCore

private var utc: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private var kst: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return cal
}

private let now = iso("2026-08-12T00:00:00Z")
private let awarder = XpAwarder(rules: .default, workflow: demoWorkflow, calendar: utc)

/// 마감일은 이벤트가 들고 다닌다(미러가 아니라). 그래서 픽스처도 이벤트에 싣는다.
private func statusEvent(from: String, to: String, due: Date? = nil) -> DomainEvent {
    DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: from, toStatus: to,
                observedAt: now, actorAccountId: "acc-me", dueDateAtObservation: due)
}

@Test func wakingA21DayBossPaysBaseTimesMultiplier() {
    let event = DomainEvent(issueKey: "DEMO-1", kind: .touched, fromStatus: nil, toStatus: nil,
                            observedAt: now, actorAccountId: "acc-me")
    let xp = awarder.baseXP(for: event,
                            issue: issue(key: "DEMO-1", status: "Verifying"),
                            statusEnteredAt: now.addingTimeInterval(-days(21)),
                            now: now)
    #expect(xp == 100)   // 40 × min(1 + 21/14, 4.0) = 40 × 2.5
}

@Test func wakeMultiplierIsCappedAtFour() {
    let event = DomainEvent(issueKey: "DEMO-1", kind: .touched, fromStatus: nil, toStatus: nil,
                            observedAt: now, actorAccountId: "acc-me")
    let xp = awarder.baseXP(for: event,
                            issue: issue(key: "DEMO-1", status: "Verifying"),
                            statusEnteredAt: now.addingTimeInterval(-days(200)),
                            now: now)
    #expect(xp == 160)   // 40 × 4.0
}

@Test func forwardTransitionGetsTheForwardMultiplier() {
    let xp = awarder.baseXP(for: statusEvent(from: "To Do", to: "In Progress"),
                            issue: issue(key: "DEMO-1", status: "In Progress"),
                            statusEnteredAt: now.addingTimeInterval(-days(21)),
                            now: now)
    #expect(xp == 150)   // 100 × 1.5
}

@Test func backwardTransitionScoresZeroNotNegative() {
    let xp = awarder.baseXP(for: statusEvent(from: "In Progress", to: "To Do"),
                            issue: issue(key: "DEMO-1", status: "To Do"),
                            statusEnteredAt: now.addingTimeInterval(-days(30)),
                            now: now)
    #expect(xp == 0)
}

@Test func finishingBeforeTheDueDatePaysABonus() {
    let xp = awarder.baseXP(
        for: statusEvent(from: "Verifying", to: "Done", due: now.addingTimeInterval(days(3))),
        issue: issue(key: "DEMO-1", status: "Done"),
        statusEnteredAt: now,   // 정체 0일 → 깨우기 XP는 40 × 1.0 × 1.5 = 60
        now: now
    )
    #expect(xp == 90)   // 60 + min(3 × 10, 80)
}

@Test func dueBonusIsCapped() {
    let xp = awarder.baseXP(
        for: statusEvent(from: "Verifying", to: "Done", due: now.addingTimeInterval(days(60))),
        issue: issue(key: "DEMO-1", status: "Done"),
        statusEnteredAt: now,
        now: now
    )
    #expect(xp == 140)   // 60 + 80(상한)
}

@Test func overdueCompletionGetsNoBonusAndNoPenalty() {
    let xp = awarder.baseXP(
        for: statusEvent(from: "Verifying", to: "Done", due: now.addingTimeInterval(-days(5))),
        issue: issue(key: "DEMO-1", status: "Done"),
        statusEnteredAt: now,
        now: now
    )
    #expect(xp == 60)
}

/// 마감 여유일도 로컬 달력의 날짜 차이로 센다. KST 정오에 완료하고 마감이 이틀 뒤면
/// 여유는 (원시 초 차이가 1.5일이어도) 2일이다.
@Test func spareDaysAreCountedInLocalCalendarDays() {
    let seoulAwarder = XpAwarder(rules: .default, workflow: demoWorkflow, calendar: kst)
    let noonKST = iso("2026-08-12T03:00:00Z")
    let event = DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "Verifying",
                            toStatus: "Done", observedAt: noonKST, actorAccountId: "acc-me",
                            priorUpdatedAt: noonKST,
                            dueDateAtObservation: iso("2026-08-14T00:00:00Z"))
    let xp = seoulAwarder.baseXP(
        for: event,
        issue: issue(key: "DEMO-1", status: "Done"),
        statusEnteredAt: noonKST,
        now: noonKST
    )
    #expect(xp == 80)   // 60 + 2 × 10
}

/// 마감 당일 완료는 여유 0일이라 보너스가 없다(감점도 없다).
@Test func finishingOnTheDueDateGetsNoBonus() {
    let seoulAwarder = XpAwarder(rules: .default, workflow: demoWorkflow, calendar: kst)
    let noonKST = iso("2026-08-12T03:00:00Z")
    let event = DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "Verifying",
                            toStatus: "Done", observedAt: noonKST, actorAccountId: "acc-me",
                            priorUpdatedAt: noonKST,
                            dueDateAtObservation: iso("2026-08-12T00:00:00Z"))
    let xp = seoulAwarder.baseXP(
        for: event,
        issue: issue(key: "DEMO-1", status: "Done"),
        statusEnteredAt: noonKST,
        now: noonKST
    )
    #expect(xp == 60)
}

@Test(arguments: [EventKind.appeared, .vanished, .dueDateChanged])
func bookkeepingEventsPayNothing(kind: EventKind) {
    let event = DomainEvent(issueKey: "DEMO-1", kind: kind, fromStatus: nil, toStatus: nil,
                            observedAt: now, actorAccountId: "acc-me")
    let xp = awarder.baseXP(for: event,
                            issue: issue(key: "DEMO-1", status: "Verifying"),
                            statusEnteredAt: now.addingTimeInterval(-days(100)),
                            now: now)
    #expect(xp == 0)
}

@Test func unmappedStatusTransitionScoresZero() {
    let xp = awarder.baseXP(for: statusEvent(from: "검토 대기", to: "보류"),
                            issue: issue(key: "DEMO-1", status: "보류"),
                            statusEnteredAt: now.addingTimeInterval(-days(30)),
                            now: now)
    #expect(xp == 0)
}
