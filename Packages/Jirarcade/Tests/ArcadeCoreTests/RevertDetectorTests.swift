import Testing
import Foundation
@testable import ArcadeCore

private func change(
    _ key: String, from: String, to: String, at: String
) -> DomainEvent {
    DomainEvent(issueKey: key, kind: .statusChanged, fromStatus: from, toStatus: to,
                observedAt: iso(at), actorAccountId: "acc-me")
}

@Test func findsAnExactReversalInsideTheWindow() {
    let events = [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-20T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-20T09:05:00Z"),
    ]

    #expect(RevertDetector.revertedIndices(in: events, windowMinutes: 10) == [0, 1])
}

/// 창을 벗어난 왕복은 되돌림이 아니다. 리뷰 반려처럼 시간이 걸린 복귀는 진짜 움직임이다.
@Test func aReversalOutsideTheWindowIsNotARevert() {
    let events = [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-20T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-20T09:30:00Z"),
    ]

    #expect(RevertDetector.revertedIndices(in: events, windowMinutes: 10).isEmpty)
}

/// 정확한 역방향이어야 한다. 다른 상태로 갔다가 돌아온 것은 되돌림이 아니다.
@Test func aDifferentDestinationIsNotARevert() {
    let events = [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-20T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "완료", at: "2026-08-20T09:05:00Z"),
    ]

    #expect(RevertDetector.revertedIndices(in: events, windowMinutes: 10).isEmpty)
}

/// 티켓이 다르면 짝이 되지 않는다.
@Test func eventsOnDifferentIssuesDoNotPair() {
    let events = [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-20T09:00:00Z"),
        change("DEMO-2", from: "검토", to: "진행 중", at: "2026-08-20T09:05:00Z"),
    ]

    #expect(RevertDetector.revertedIndices(in: events, windowMinutes: 10).isEmpty)
}

/// 반환값은 **넘긴 배열 기준의 인덱스**다. 입력이 시간순이 아니어도 위치가 맞아야 한다.
@Test func indicesReferToThePassedArrayNotSortedOrder() {
    let events = [
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-20T09:05:00Z"),
        change("DEMO-9", from: "대기", to: "진행 중", at: "2026-08-19T09:00:00Z"),
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-20T09:00:00Z"),
    ]

    #expect(RevertDetector.revertedIndices(in: events, windowMinutes: 10) == [0, 2])
}

/// 상태를 모르는 이벤트는 짝이 될 수 없다.
@Test func eventsWithoutStatusesDoNotPair() {
    let events = [
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: nil, toStatus: "검토",
                    observedAt: iso("2026-08-20T09:00:00Z"), actorAccountId: nil),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-20T09:05:00Z"),
    ]

    #expect(RevertDetector.revertedIndices(in: events, windowMinutes: 10).isEmpty)
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

    #expect(RevertDetector.revertedIndices(in: events, windowMinutes: 10).isEmpty)
}
