import Testing
import Foundation
@testable import ArcadeCore

private func change(
    _ key: String, from: String, to: String, at: String
) -> DomainEvent {
    DomainEvent(issueKey: key, kind: .statusChanged, fromStatus: from, toStatus: to,
                observedAt: iso(at), actorAccountId: "acc-me")
}

private func revertedIndices(_ events: [DomainEvent], windowMinutes: Double = 10) -> Set<Int> {
    Set(
        RevertDetector.chronology(of: events, windowMinutes: windowMinutes)
            .filter(\.isReverted)
            .map(\.index)
    )
}

@Test func findsAnExactReversalInsideTheWindow() {
    let events = [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-20T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-20T09:05:00Z"),
    ]

    #expect(revertedIndices(events) == [0, 1])
}

/// 창을 벗어난 왕복은 되돌림이 아니다. 리뷰 반려처럼 시간이 걸린 복귀는 진짜 움직임이다.
@Test func aReversalOutsideTheWindowIsNotARevert() {
    let events = [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-20T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-20T09:30:00Z"),
    ]

    #expect(revertedIndices(events).isEmpty)
}

/// 정확한 역방향이어야 한다. 다른 상태로 갔다가 돌아온 것은 되돌림이 아니다.
@Test func aDifferentDestinationIsNotARevert() {
    let events = [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-20T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "완료", at: "2026-08-20T09:05:00Z"),
    ]

    #expect(revertedIndices(events).isEmpty)
}

/// 티켓이 다르면 짝이 되지 않는다.
@Test func eventsOnDifferentIssuesDoNotPair() {
    let events = [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-20T09:00:00Z"),
        change("DEMO-2", from: "검토", to: "진행 중", at: "2026-08-20T09:05:00Z"),
    ]

    #expect(revertedIndices(events).isEmpty)
}

/// 반환값은 **넘긴 배열 기준의 인덱스**다. 입력이 시간순이 아니어도 위치가 맞아야 한다.
@Test func indicesReferToThePassedArrayNotSortedOrder() {
    let events = [
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-20T09:05:00Z"),
        change("DEMO-9", from: "대기", to: "진행 중", at: "2026-08-19T09:00:00Z"),
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-20T09:00:00Z"),
    ]

    #expect(revertedIndices(events) == [0, 2])
}

/// 상태를 모르는 이벤트는 짝이 될 수 없다.
@Test func eventsWithoutStatusesDoNotPair() {
    let events = [
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: nil, toStatus: "검토",
                    observedAt: iso("2026-08-20T09:00:00Z"), actorAccountId: nil),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-20T09:05:00Z"),
    ]

    #expect(revertedIndices(events).isEmpty)
}

/// Swift의 `nil == nil`은 참이므로, 양쪽 상태가 모두 nil이면 false positive로 짝지어진다.
/// 이 가드가 없으면 이 쌍이 잘못 되돌림으로 판정된다.
@Test func nilStatusesCannotReverseEachOther() {
    let events = [
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: nil, toStatus: "검토",
                    observedAt: iso("2026-08-20T09:00:00Z"), actorAccountId: nil),
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "검토", toStatus: nil,
                    observedAt: iso("2026-08-20T09:05:00Z"), actorAccountId: nil),
    ]

    #expect(revertedIndices(events).isEmpty)
}

/// 순서를 검출기가 만든다. 호출자가 따로 정렬하지 않아도 시간순으로 걸을 수 있어야 한다.
@Test func stepsComeBackInChronologicalOrder() {
    let events = [
        change("DEMO-1", from: "대기", to: "진행 중", at: "2026-08-20T12:00:00Z"),
        change("DEMO-2", from: "대기", to: "진행 중", at: "2026-08-18T12:00:00Z"),
        change("DEMO-3", from: "대기", to: "진행 중", at: "2026-08-19T12:00:00Z"),
    ]

    let steps = RevertDetector.chronology(of: events, windowMinutes: 10)

    #expect(steps.map(\.index) == [1, 2, 0])
    #expect(steps.allSatisfy { $0.isReverted == false })
}

/// 이벤트를 품고 있는 값의 배열도 그대로 넘긴다. 인덱스는 **그 배열** 기준이어야 한다 —
/// 중간 배열을 만들어 넘기던 시절에는 이 대응이 `map`이 개수를 보존한다는 우연에 기댔다.
@Test func theGenericFormIndexesTheArrayYouPassed() {
    struct Wrapped { let event: DomainEvent; let tag: String }
    let wrapped = [
        Wrapped(event: change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-20T09:05:00Z"),
                tag: "돌아온 쪽"),
        Wrapped(event: change("DEMO-9", from: "대기", to: "진행 중", at: "2026-08-19T09:00:00Z"),
                tag: "무관한 티켓"),
        Wrapped(event: change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-20T09:00:00Z"),
                tag: "떠난 쪽"),
    ]

    let steps = RevertDetector.chronology(of: wrapped, event: \.event, windowMinutes: 10)

    #expect(steps.filter(\.isReverted).map { wrapped[$0.index].tag }.sorted()
            == ["돌아온 쪽", "떠난 쪽"])
}
