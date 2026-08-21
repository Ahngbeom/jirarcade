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

/// 기존 이벤트는 전부 관측(diff)에서 왔다. 마이그레이션이 이 값을 채우지 않으면
/// 관측 일수 계산이 백필 이벤트와 구분되지 않는다(스펙 §3.1).
@MainActor
@Test func existingEventsDefaultToObservedOrigin() throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let when = iso("2026-08-13T09:00:00Z")
    try store.applySync(
        issues: [], events: [
            DomainEvent(issueKey: "MPT-1", kind: .statusChanged,
                        fromStatus: "To Do", toStatus: "In Progress",
                        observedAt: when, actorAccountId: "acc-me")
        ], observedAt: when
    )
    let records = try store.rawEventRecords()
    #expect(records.count == 1)
    #expect(records[0].origin == EventOrigin.observed)
    #expect(records[0].sourceHistoryId == nil)
}

@Test func originConstantsAreStable() {
    // rawValue 문자열이 저장되므로 바뀌면 과거 레코드의 의미가 달라진다.
    #expect(EventOrigin.observed == "observed")
    #expect(EventOrigin.backfill == "backfill")
}

/// 진짜 마이그레이션 위험은 "이미 저장된 로우를 열 수 있는가"다. 인메모리 컨테이너는
/// 매번 새 스토어를 만들어 그 경로를 아예 지나지 않으므로, 파일 기반으로 확인한다.
///
/// 같은 파일을 컨테이너 두 개가 차례로 여는 것으로 "저장했다 다시 연다"를 재현한다.
/// 이 스키마 이전 버전으로 쓴 파일을 만들 수는 없지만, 최소한 파일 기반 왕복에서
/// origin이 유실되지 않는지는 확인할 수 있다.
@MainActor
@Test func eventsSurviveAFileBasedRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("jirarcade-migration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("store.sqlite")

    let when = iso("2026-08-20T09:00:00Z")
    do {
        let container = try ModelContainer(
            for: IssueSnapshot.self, IssueEventRecord.self, SyncRunRecord.self,
            configurations: ModelConfiguration(url: url)
        )
        let store = ArcadeStore(container: container)
        try store.applySync(
            issues: [], events: [
                DomainEvent(issueKey: "DEMO-1", kind: .statusChanged,
                            fromStatus: "To Do", toStatus: "In Progress",
                            observedAt: when, actorAccountId: "acc-me")
            ], observedAt: when
        )
    }

    // 같은 파일을 새 컨테이너로 다시 연다.
    let reopened = try ModelContainer(
        for: IssueSnapshot.self, IssueEventRecord.self, SyncRunRecord.self,
        configurations: ModelConfiguration(url: url)
    )
    let store = ArcadeStore(container: reopened)
    let records = try store.rawEventRecords()

    let record = try #require(records.first)
    #expect(records.count == 1, "저장한 이벤트가 다시 열려야 한다")
    #expect(record.origin == EventOrigin.observed)
    #expect(record.sourceHistoryId == nil)
}

/// 백필을 두 번 돌려도 이벤트가 중복되지 않는다. 재개 지점을 정확히 맞출 필요가 없어지는
/// 것이 이 검사의 진짜 이득이다 — 겹쳐 훑어도 안전하다(스펙 §7.2).
@MainActor
@Test func backfillEventsAreDeduplicatedByHistoryId() throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let event = DomainEvent(
        issueKey: "MPT-1", kind: .statusChanged, fromStatus: "To Do", toStatus: "In Progress",
        observedAt: iso("2023-03-02T12:13:52Z"), actorAccountId: "acc-me"
    )

    let first = try store.appendBackfillEvents([event], historyIds: ["50347"],
                                               fullyRestoredKeys: [])
    let second = try store.appendBackfillEvents([event], historyIds: ["50347"],
                                                fullyRestoredKeys: [])

    #expect(first == 1)
    #expect(second == 0, "같은 historyId는 다시 넣지 않는다")
    #expect(try store.loadEvents().count == 1)
}

/// 시각과 상태명이 같아도 historyId가 다르면 별개 전이다 — 왕복 전이가 그렇다.
@MainActor
@Test func differentHistoryIdsAreDistinctEvents() throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let when = iso("2023-03-02T12:13:52Z")
    let a = DomainEvent(issueKey: "MPT-1", kind: .statusChanged,
                        fromStatus: "To Do", toStatus: "In Progress",
                        observedAt: when, actorAccountId: "acc-me")
    let b = DomainEvent(issueKey: "MPT-1", kind: .statusChanged,
                        fromStatus: "In Progress", toStatus: "To Do",
                        observedAt: when, actorAccountId: "acc-me")

    _ = try store.appendBackfillEvents([a, b], historyIds: ["1", "2"], fullyRestoredKeys: [])
    #expect(try store.loadEvents().count == 2)
}

/// 백필이 3년 전 이벤트를 넣어도 "관측 N일차"가 3년으로 뛰면 안 된다.
/// 그러면 정체 판정이 근사에서 정확으로 잘못 승격되고 UI도 거짓말을 한다(스펙 §3.1).
@MainActor
@Test func observationDayCountIgnoresBackfillEvents() throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let today = iso("2026-08-13T09:00:00Z")

    let run = try store.beginSyncRun(at: today)
    try store.finishSyncRun(run, at: today, issueCount: 1, failure: nil)

    _ = try store.appendBackfillEvents([
        DomainEvent(issueKey: "MPT-1", kind: .statusChanged,
                    fromStatus: "To Do", toStatus: "In Progress",
                    observedAt: iso("2023-01-01T00:00:00Z"), actorAccountId: "acc-me")
    ], historyIds: ["1"], fullyRestoredKeys: [])

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    #expect(try store.observationDayCount(now: today, calendar: utc) == 1)
}

// MARK: - 백필이 라이브 관측을 대체한다

/// 라이브 관측 전이 하나를 넣는다. `applySync(issues: nil, ...)`은 미러를 건드리지 않고
/// 이벤트만 기록하므로, 만들어지는 레코드는 `origin == observed`에 `sourceHistoryId == nil`이다.
@MainActor
private func recordLiveTransition(
    _ store: ArcadeStore, key: String, at when: Date
) throws {
    try store.applySync(issues: nil, events: [
        DomainEvent(issueKey: key, kind: .statusChanged,
                    fromStatus: "In Progress", toStatus: "Done",
                    observedAt: when, actorAccountId: "acc-me")
    ], observedAt: when)
}

/// changelog를 온전히 받은 티켓은 라이브 관측 전이를 **대체**한다.
///
/// historyId 중복 검사는 백필끼리만 막는다 — 라이브 이벤트는 `sourceHistoryId`가 nil이라
/// 그 집합에 없으므로, 지우지 않으면 같은 실제 전이가 두 행으로 남고 둘 다 채점된다(리뷰 C1).
@MainActor
@Test func fullyRestoredTicketLosesItsLiveObservedTransitions() throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    try recordLiveTransition(store, key: "MPT-1", at: iso("2026-08-10T09:00:00Z"))
    // 같은 백필에 들어 있지만 changelog가 온전하지 않은 티켓. 불완전한 이력으로 관측
    // 기록을 지우면 있었던 전이가 사라지므로 대체 대상이 아니다.
    try recordLiveTransition(store, key: "MPT-2", at: iso("2026-08-10T09:00:00Z"))

    _ = try store.appendBackfillEvents(
        [DomainEvent(issueKey: "MPT-1", kind: .statusChanged,
                     fromStatus: "In Progress", toStatus: "Done",
                     observedAt: iso("2026-08-07T18:00:00Z"), actorAccountId: "acc-me")],
        historyIds: ["h-1"], fullyRestoredKeys: ["MPT-1"]
    )

    let records = try store.rawEventRecords()
    #expect(records.filter { $0.issueKey == "MPT-1" }.map(\.origin) == [EventOrigin.backfill],
            "온전히 받은 티켓에는 백필 이벤트만 남는다")
    #expect(records.filter { $0.issueKey == "MPT-2" }.map(\.origin) == [EventOrigin.observed],
            "부분 복원된 티켓의 관측 기록은 지우지 않는다")
}

/// 대체 대상은 `.statusChanged`뿐이다. `.appeared`/`.vanished`/`.touched`는 관측 자체의
/// 기록이라 changelog에 대응물이 없다 — 함께 지우면 대체가 아니라 소실이 된다.
@MainActor
@Test func replacingLiveTransitionsKeepsObservationOnlyEvents() throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let when = iso("2026-08-10T09:00:00Z")
    try store.applySync(issues: nil, events: [
        DomainEvent(issueKey: "MPT-1", kind: .appeared, fromStatus: nil, toStatus: "To Do",
                    observedAt: when, actorAccountId: "acc-me"),
        DomainEvent(issueKey: "MPT-1", kind: .touched, fromStatus: nil, toStatus: nil,
                    observedAt: when, actorAccountId: "acc-me"),
        DomainEvent(issueKey: "MPT-1", kind: .vanished, fromStatus: "Done", toStatus: nil,
                    observedAt: when, actorAccountId: "acc-me"),
        DomainEvent(issueKey: "MPT-1", kind: .statusChanged,
                    fromStatus: "In Progress", toStatus: "Done",
                    observedAt: when, actorAccountId: "acc-me"),
    ], observedAt: when)

    _ = try store.appendBackfillEvents(
        [DomainEvent(issueKey: "MPT-1", kind: .statusChanged,
                     fromStatus: "In Progress", toStatus: "Done",
                     observedAt: iso("2026-08-07T18:00:00Z"), actorAccountId: "acc-me")],
        historyIds: ["h-1"], fullyRestoredKeys: ["MPT-1"]
    )

    let kinds = Set(try store.rawEventRecords()
        .filter { $0.origin == EventOrigin.observed }
        .map(\.kindRaw))
    #expect(kinds == [EventKind.appeared.rawValue, EventKind.touched.rawValue,
                      EventKind.vanished.rawValue],
            "관측 자체의 기록은 남는다 — 지워지는 것은 전이뿐이다")
}

/// 백필을 두 번 돌려도 결과가 같다. 두 번째 호출에는 지울 관측 전이가 이미 없고
/// historyId 검사가 삽입을 막으므로 이벤트 로그가 그대로여야 한다.
@MainActor
@Test func replacingLiveTransitionsIsIdempotent() throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    try recordLiveTransition(store, key: "MPT-1", at: iso("2026-08-10T09:00:00Z"))
    let events = [DomainEvent(issueKey: "MPT-1", kind: .statusChanged,
                              fromStatus: "In Progress", toStatus: "Done",
                              observedAt: iso("2026-08-07T18:00:00Z"),
                              actorAccountId: "acc-me")]

    let first = try store.appendBackfillEvents(events, historyIds: ["h-1"],
                                               fullyRestoredKeys: ["MPT-1"])
    let afterFirst = try store.loadEvents()
    let second = try store.appendBackfillEvents(events, historyIds: ["h-1"],
                                                fullyRestoredKeys: ["MPT-1"])

    #expect(first == 1)
    #expect(second == 0)
    #expect(try store.loadEvents() == afterFirst)
}

/// 전이를 하나도 만들지 않은 티켓도 대체한다. "changelog에 상태 변경이 없다"도 그
/// 티켓에 대한 완전한 사실이므로, 라이브가 뭉쳐서 기록한 전이를 남길 근거가 되지 못한다.
@MainActor
@Test func fullyRestoredTicketWithNoTransitionsStillReplaces() throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    try recordLiveTransition(store, key: "MPT-1", at: iso("2026-08-10T09:00:00Z"))

    let inserted = try store.appendBackfillEvents([], historyIds: [],
                                                  fullyRestoredKeys: ["MPT-1"])

    #expect(inserted == 0)
    #expect(try store.loadEvents().isEmpty, "빈 이벤트 배열이라고 대체를 건너뛰면 안 된다")
}
