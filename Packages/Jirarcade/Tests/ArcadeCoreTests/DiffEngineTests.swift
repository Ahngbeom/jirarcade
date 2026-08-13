import Testing
import Foundation
@testable import ArcadeCore

private let observedAt = iso("2026-08-12T09:00:00Z")
private let engine = DiffEngine()

@Test func newIssueProducesAppeared() {
    let events = engine.diff(previous: [:],
                             current: [issue(key: "DEMO-1", status: "To Do")],
                             observedAt: observedAt)
    #expect(events.count == 1)
    #expect(events[0].kind == .appeared)
    #expect(events[0].toStatus == "To Do")
    #expect(events[0].observedAt == observedAt)
}

@Test func statusChangeCarriesBothEnds() {
    let before = issue(key: "DEMO-1", status: "In Progress", updated: iso("2026-08-11T00:00:00Z"))
    let after = issue(key: "DEMO-1", status: "In Review", updated: iso("2026-08-12T00:00:00Z"))
    let events = engine.diff(previous: ["DEMO-1": before], current: [after], observedAt: observedAt)
    #expect(events.count == 1)
    #expect(events[0].kind == .statusChanged)
    #expect(events[0].fromStatus == "In Progress")
    #expect(events[0].toStatus == "In Review")
}

@Test func updatedTimestampAloneProducesTouched() {
    let before = issue(key: "DEMO-1", status: "Verifying", updated: iso("2026-08-11T00:00:00Z"))
    let after = issue(key: "DEMO-1", status: "Verifying", updated: iso("2026-08-12T00:00:00Z"))
    let events = engine.diff(previous: ["DEMO-1": before], current: [after], observedAt: observedAt)
    #expect(events.map(\.kind) == [.touched])
}

@Test func noChangeProducesNoEvents() {
    let same = issue(key: "DEMO-1", status: "Verifying", updated: iso("2026-08-11T00:00:00Z"))
    let events = engine.diff(previous: ["DEMO-1": same], current: [same], observedAt: observedAt)
    #expect(events.isEmpty)
}

@Test func dueDateChangeIsItsOwnEvent() {
    let before = issue(key: "DEMO-1", status: "In Progress",
                       due: iso("2026-08-20T00:00:00Z"), updated: iso("2026-08-11T00:00:00Z"))
    let after = issue(key: "DEMO-1", status: "In Progress",
                      due: iso("2026-08-25T00:00:00Z"), updated: iso("2026-08-12T00:00:00Z"))
    let events = engine.diff(previous: ["DEMO-1": before], current: [after], observedAt: observedAt)
    #expect(Set(events.map(\.kind)) == [.touched, .dueDateChanged])
}

@Test func statusChangeSuppressesTouched() {
    let before = issue(key: "DEMO-1", status: "In Progress", updated: iso("2026-08-11T00:00:00Z"))
    let after = issue(key: "DEMO-1", status: "Verifying", updated: iso("2026-08-12T00:00:00Z"))
    let events = engine.diff(previous: ["DEMO-1": before], current: [after], observedAt: observedAt)
    #expect(events.map(\.kind) == [.statusChanged], "상태 전이는 그 자체로 갱신이므로 touched를 겹쳐 내지 않는다")
}

@Test func missingIssueProducesVanished() {
    let before = issue(key: "DEMO-1", status: "In Progress")
    let events = engine.diff(previous: ["DEMO-1": before], current: [], observedAt: observedAt)
    #expect(events.map(\.kind) == [.vanished])
    #expect(events[0].fromStatus == "In Progress")
}

/// 정체 기준선은 diff 시점에만 알 수 있다 — 미러는 곧바로 덮인다.
@Test func changeEventsCarryThePriorUpdatedAtAsTheStagnationBaseline() {
    let old = iso("2026-07-01T00:00:00Z")
    let before = issue(key: "DEMO-1", status: "In Progress", updated: old)
    let after = issue(key: "DEMO-1", status: "In Review", updated: iso("2026-08-12T00:00:00Z"))

    let transition = engine.diff(previous: ["DEMO-1": before], current: [after],
                                 observedAt: observedAt)
    #expect(transition[0].priorUpdatedAt == old)

    let touchedAfter = issue(key: "DEMO-1", status: "In Progress", updated: iso("2026-08-12T00:00:00Z"))
    let touch = engine.diff(previous: ["DEMO-1": before], current: [touchedAfter],
                            observedAt: observedAt)
    #expect(touch[0].priorUpdatedAt == old)

    let gone = engine.diff(previous: ["DEMO-1": before], current: [], observedAt: observedAt)
    #expect(gone[0].priorUpdatedAt == old)
}

/// 마감일도 관측 시점 값을 싣는다. 티켓이 조회 결과에서 사라지면 미러에서도 사라지므로,
/// 여기서 안 실으면 마감 전 완료 보너스가 나중에 증발한다.
@Test func changeEventsCarryTheDueDateAtObservation() {
    let due = iso("2026-08-20T00:00:00Z")
    let before = issue(key: "DEMO-1", status: "Verifying", due: due,
                       updated: iso("2026-08-11T00:00:00Z"))
    let after = issue(key: "DEMO-1", status: "Done", due: due,
                      updated: iso("2026-08-12T00:00:00Z"))

    let transition = engine.diff(previous: ["DEMO-1": before], current: [after],
                                 observedAt: observedAt)
    #expect(transition[0].dueDateAtObservation == due)

    let gone = engine.diff(previous: ["DEMO-1": before], current: [], observedAt: observedAt)
    #expect(gone[0].dueDateAtObservation == due)
}

@Test func eventsForATicketWithoutADueDateCarryNil() {
    let before = issue(key: "DEMO-1", status: "Verifying", updated: iso("2026-08-11T00:00:00Z"))
    let after = issue(key: "DEMO-1", status: "Done", updated: iso("2026-08-12T00:00:00Z"))
    let events = engine.diff(previous: ["DEMO-1": before], current: [after],
                             observedAt: observedAt)
    #expect(events[0].dueDateAtObservation == nil)
}

/// 마감일이 바뀐 순간의 이벤트는 **새** 마감일을 싣는다.
@Test func dueDateChangeCarriesTheNewDueDate() {
    let before = issue(key: "DEMO-1", status: "In Progress", due: iso("2026-08-20T00:00:00Z"),
                       updated: iso("2026-08-11T00:00:00Z"))
    let after = issue(key: "DEMO-1", status: "In Progress", due: iso("2026-08-25T00:00:00Z"),
                      updated: iso("2026-08-12T00:00:00Z"))
    let events = engine.diff(previous: ["DEMO-1": before], current: [after],
                             observedAt: observedAt)
    #expect(events.allSatisfy { $0.dueDateAtObservation == iso("2026-08-25T00:00:00Z") })
}

@Test func appearedHasNoPriorUpdatedAt() {
    let events = engine.diff(previous: [:],
                             current: [issue(key: "DEMO-1", status: "To Do")],
                             observedAt: observedAt)
    #expect(events[0].priorUpdatedAt == nil, "직전 값이 없으므로 근사조차 불가능하다")
}

@Test func outputOrderIsDeterministic() {
    let previous: [String: ObservedIssue] = [:]
    let current = [
        issue(key: "DEMO-9", status: "In Progress"),
        issue(key: "DEMO-1", status: "In Progress"),
        issue(key: "DEMO-5", status: "In Progress"),
    ]
    let first = engine.diff(previous: previous, current: current, observedAt: observedAt)
    let second = engine.diff(previous: previous, current: current.reversed(), observedAt: observedAt)
    #expect(first.map(\.issueKey) == ["DEMO-1", "DEMO-5", "DEMO-9"])
    #expect(first == second)
}
