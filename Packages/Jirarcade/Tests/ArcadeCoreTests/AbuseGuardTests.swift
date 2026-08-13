import Testing
import Foundation
@testable import ArcadeCore

private var utc: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private let guard_ = AbuseGuard(rules: .default, calendar: utc)

private func scored(_ key: String, from: String?, to: String?, at: Date, xp: Int) -> ScoredEvent {
    ScoredEvent(
        event: DomainEvent(issueKey: key, kind: .statusChanged, fromStatus: from, toStatus: to,
                           observedAt: at, actorAccountId: "acc-me"),
        xp: xp
    )
}

private func touched(_ key: String, at: Date, xp: Int) -> ScoredEvent {
    ScoredEvent(
        event: DomainEvent(issueKey: key, kind: .touched, fromStatus: nil, toStatus: nil,
                           observedAt: at, actorAccountId: "acc-me"),
        xp: xp
    )
}

@Test func identicalTransitionWithin24HoursPaysOnce() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.applyVoids(to: [
        scored("DEMO-1", from: "To Do", to: "In Progress", at: base, xp: 100),
        scored("DEMO-1", from: "To Do", to: "In Progress", at: base.addingTimeInterval(hours(3)), xp: 100),
    ])
    #expect(result.map(\.xp) == [100, 0])
}

@Test func identicalTransitionAfter24HoursPaysAgain() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.applyVoids(to: [
        scored("DEMO-1", from: "To Do", to: "In Progress", at: base, xp: 100),
        scored("DEMO-1", from: "To Do", to: "In Progress", at: base.addingTimeInterval(hours(25)), xp: 100),
    ])
    #expect(result.map(\.xp) == [100, 100])
}

/// 두 창 규칙(`duplicateWindowHours`·`revertWindowMinutes`)의 경계는 모두 "이하"다.
@Test func identicalTransitionExactlyAtTheWindowEdgeIsStillADuplicate() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.applyVoids(to: [
        scored("DEMO-1", from: "To Do", to: "In Progress", at: base, xp: 100),
        scored("DEMO-1", from: "To Do", to: "In Progress", at: base.addingTimeInterval(hours(24)), xp: 100),
    ])
    #expect(result.map(\.xp) == [100, 0])
}

@Test func identicalTransitionOneSecondPastTheWindowPaysAgain() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.applyVoids(to: [
        scored("DEMO-1", from: "To Do", to: "In Progress", at: base, xp: 100),
        scored("DEMO-1", from: "To Do", to: "In Progress",
               at: base.addingTimeInterval(hours(24) + 1), xp: 100),
    ])
    #expect(result.map(\.xp) == [100, 100])
}

/// 정체 기준선 수정(priorUpdatedAt) 이후 `touched` 하나가 최대 160 XP를 낸다.
/// 쿨다운이 없으면 코멘트를 반복해 일일 상한까지 채울 수 있다.
@Test func repeatedTouchesOnTheSameTicketPayOnlyOncePerWindow() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.applyVoids(to: [
        touched("DEMO-1", at: base, xp: 160),
        touched("DEMO-1", at: base.addingTimeInterval(minutes(5)), xp: 160),
        touched("DEMO-1", at: base.addingTimeInterval(hours(3)), xp: 160),
    ])
    #expect(result.map(\.xp) == [160, 0, 0])
}

@Test func touchesOnDifferentTicketsDoNotBlockEachOther() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.applyVoids(to: [
        touched("DEMO-1", at: base, xp: 160),
        touched("DEMO-2", at: base.addingTimeInterval(minutes(5)), xp: 160),
    ])
    #expect(result.map(\.xp) == [160, 160])
}

@Test func touchPaysAgainAfterTheWindow() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.applyVoids(to: [
        touched("DEMO-1", at: base, xp: 160),
        touched("DEMO-1", at: base.addingTimeInterval(hours(25)), xp: 160),
    ])
    #expect(result.map(\.xp) == [160, 160])
}

@Test func revertingWithin10MinutesVoidsTheOriginalAward() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.applyVoids(to: [
        scored("DEMO-1", from: "In Progress", to: "In Review", at: base, xp: 150),
        scored("DEMO-1", from: "In Review", to: "In Progress", at: base.addingTimeInterval(minutes(4)), xp: 0),
    ])
    #expect(result.map(\.xp) == [0, 0])
}

@Test func revertingAfterTheWindowKeepsTheAward() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.applyVoids(to: [
        scored("DEMO-1", from: "In Progress", to: "In Review", at: base, xp: 150),
        scored("DEMO-1", from: "In Review", to: "In Progress", at: base.addingTimeInterval(minutes(30)), xp: 0),
    ])
    #expect(result.map(\.xp) == [150, 0])
}

// MARK: - 일일 상한
//
// 상한은 스펙 §5.6에 따라 "연속 보너스 적용 후"에 걸리므로 무효화 단계와 분리되어 있다.
// ScoreEngine이 두 단계 사이에 배수를 끼워 넣는다. 여기서는 상한만 단독으로 검증한다.

@Test func dailyCapTruncatesTheOverflowEvent() {
    let base = iso("2026-08-12T09:00:00Z")
    let events = (1...5).map {
        scored("DEMO-\($0)", from: "To Do", to: "In Progress",
               at: base.addingTimeInterval(minutes(Double($0) * 20)), xp: 300)
    }
    let result = guard_.applyDailyCap(to: events)
    #expect(result.map(\.xp) == [300, 300, 300, 300, 0])
    #expect(result.reduce(0) { $0 + $1.xp } == 1_200)
}

@Test func dailyCapResetsOnTheNextDay() {
    let day1 = iso("2026-08-12T09:00:00Z")
    let day2 = iso("2026-08-13T09:00:00Z")
    let result = guard_.applyDailyCap(to: [
        scored("DEMO-1", from: "To Do", to: "In Progress", at: day1, xp: 1_200),
        scored("DEMO-2", from: "To Do", to: "In Progress", at: day2, xp: 500),
    ])
    #expect(result.map(\.xp) == [1_200, 500])
}

@Test func capPartiallyAwardsTheEventThatCrossesTheLimit() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.applyDailyCap(to: [
        scored("DEMO-1", from: "To Do", to: "In Progress", at: base, xp: 1_000),
        scored("DEMO-2", from: "To Do", to: "In Progress", at: base.addingTimeInterval(hours(1)), xp: 500),
    ])
    #expect(result.map(\.xp) == [1_000, 200])
}

@Test func inputOrderIsPreserved() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.applyVoids(to: [
        scored("DEMO-9", from: "To Do", to: "In Progress", at: base, xp: 50),
        scored("DEMO-1", from: "To Do", to: "In Progress", at: base.addingTimeInterval(hours(1)), xp: 50),
    ])
    #expect(result.map(\.event.issueKey) == ["DEMO-9", "DEMO-1"])
}
