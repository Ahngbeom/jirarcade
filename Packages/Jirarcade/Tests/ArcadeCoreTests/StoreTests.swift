import Testing
import Foundation
import SwiftData
@testable import ArcadeCore

private var utc: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

@MainActor
private func makeStore() throws -> ArcadeStore {
    ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
}

@MainActor
@Test func mirrorRoundTripsThroughSwiftData() throws {
    let store = try makeStore()
    let now = iso("2026-08-12T09:00:00Z")
    let one = issue(key: "DEMO-1", status: "In Progress", due: iso("2026-08-20T00:00:00Z"))

    try store.applySync(issues: [one], events: [], observedAt: now)
    let mirror = try store.loadMirror()

    #expect(mirror.count == 1)
    #expect(mirror["DEMO-1"] == one)
}

@MainActor
@Test func syncUpdatesExistingRowsInsteadOfDuplicating() throws {
    let store = try makeStore()
    let day1 = iso("2026-08-11T09:00:00Z")
    let day2 = iso("2026-08-12T09:00:00Z")

    try store.applySync(issues: [issue(key: "DEMO-1", status: "In Progress", updated: day1)],
                        events: [], observedAt: day1)
    try store.applySync(issues: [issue(key: "DEMO-1", status: "Verifying", updated: day2)],
                        events: [], observedAt: day2)

    let mirror = try store.loadMirror()
    #expect(mirror.count == 1)
    #expect(mirror["DEMO-1"]?.statusName == "Verifying")
}

@MainActor
@Test func issuesAbsentFromTheSyncAreRemovedFromTheMirror() throws {
    let store = try makeStore()
    let now = iso("2026-08-12T09:00:00Z")
    try store.applySync(issues: [issue(key: "DEMO-1", status: "In Progress"),
                                 issue(key: "DEMO-2", status: "In Progress")],
                        events: [], observedAt: now)
    try store.applySync(issues: [issue(key: "DEMO-1", status: "In Progress")],
                        events: [], observedAt: now)

    let mirror = try store.loadMirror()
    #expect(Set(mirror.keys) == ["DEMO-1"])
}

/// nil은 "미러를 건드리지 마라", []는 "전부 사라졌다"다.
/// 둘을 구분하지 않으면 미러가 남아 다음 diff가 같은 vanished를 또 만든다.
@MainActor
@Test func nilLeavesTheMirrorAloneWhileEmptyClearsIt() throws {
    let store = try makeStore()
    let now = iso("2026-08-12T09:00:00Z")
    try store.applySync(issues: [issue(key: "DEMO-1", status: "In Progress")],
                        events: [], observedAt: now)

    try store.applySync(issues: nil, events: [], observedAt: now)
    #expect(try store.loadMirror().count == 1, "nil은 미러를 보존한다")

    try store.applySync(issues: [], events: [], observedAt: now)
    #expect(try store.loadMirror().isEmpty, "[]는 미러를 비운다")
}

@MainActor
@Test func eventsAccumulateAndAreNeverReplaced() throws {
    let store = try makeStore()
    let day1 = iso("2026-08-11T09:00:00Z")
    let day2 = iso("2026-08-12T09:00:00Z")

    let first = DomainEvent(issueKey: "DEMO-1", kind: .appeared, fromStatus: nil,
                            toStatus: "To Do", observedAt: day1, actorAccountId: "acc-me")
    let second = DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "To Do",
                             toStatus: "In Progress", observedAt: day2, actorAccountId: "acc-me")

    try store.applySync(issues: nil, events: [first], observedAt: day1)
    try store.applySync(issues: nil, events: [second], observedAt: day2)

    let events = try store.loadEvents()
    #expect(events.count == 2)
    #expect(events.map(\.kind) == [.appeared, .statusChanged], "시간순으로 돌려준다")
    #expect(events[1].fromStatus == "To Do")
}

/// 채점이 미러 대신 보는 두 필드는 영속을 왕복해도 살아남아야 한다.
/// 값이 사라지면 재집계가 조용히 다른 점수를 낸다.
@MainActor
@Test func eventBaselinesSurviveTheRoundTrip() throws {
    let store = try makeStore()
    let day = iso("2026-08-12T09:00:00Z")
    let baseline = iso("2026-07-01T00:00:00Z")
    let due = iso("2026-08-20T00:00:00Z")

    let withBoth = DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "In Progress",
                               toStatus: "In Review", observedAt: day,
                               actorAccountId: "acc-me", priorUpdatedAt: baseline,
                               dueDateAtObservation: due)
    let withNeither = DomainEvent(issueKey: "DEMO-2", kind: .appeared, fromStatus: nil,
                                  toStatus: "To Do", observedAt: day.addingTimeInterval(1),
                                  actorAccountId: "acc-me", priorUpdatedAt: nil,
                                  dueDateAtObservation: nil)

    try store.applySync(issues: nil, events: [withBoth, withNeither], observedAt: day)

    let loaded = try store.loadEvents()
    #expect(loaded[0].priorUpdatedAt == baseline)
    #expect(loaded[0].dueDateAtObservation == due)
    #expect(loaded[1].priorUpdatedAt == nil)
    #expect(loaded[1].dueDateAtObservation == nil)
}

@MainActor
@Test func syncRunRecordsSuccessAndFailure() throws {
    let store = try makeStore()
    let start = iso("2026-08-12T09:00:00Z")

    let ok = try store.beginSyncRun(at: start)
    try store.finishSyncRun(ok, at: start.addingTimeInterval(2), issueCount: 50, failure: nil)

    let failed = try store.beginSyncRun(at: start.addingTimeInterval(300))
    try store.finishSyncRun(failed, at: start.addingTimeInterval(302), issueCount: 0,
                            failure: "offline")

    #expect(try store.observationDayCount(now: start.addingTimeInterval(days(3)),
                                          calendar: utc) == 4)
}

@MainActor
@Test func observationDayCountIsOneOnTheFirstDay() throws {
    let store = try makeStore()
    let start = iso("2026-08-12T09:00:00Z")
    let run = try store.beginSyncRun(at: start)
    try store.finishSyncRun(run, at: start, issueCount: 1, failure: nil)
    #expect(try store.observationDayCount(now: start.addingTimeInterval(hours(5)),
                                          calendar: utc) == 1)
}

@MainActor
@Test func observationDayCountIsZeroBeforeAnySuccessfulSync() throws {
    let store = try makeStore()
    #expect(try store.observationDayCount(now: iso("2026-08-12T09:00:00Z"),
                                          calendar: utc) == 0)
}
