import Testing
import Foundation
@testable import ArcadeCore

private let base = iso("2026-08-01T00:00:00Z")

private func event(
    _ key: String, _ kind: EventKind, at offset: Double
) -> DomainEvent {
    DomainEvent(
        issueKey: key, kind: kind, fromStatus: nil, toStatus: nil,
        observedAt: base.addingTimeInterval(days(offset)), actorAccountId: "acc-me"
    )
}

@Test func takesTheLatestStatusChangePerIssue() {
    let map = StatusTimeline.latestStatusEntry(from: [
        event("DEMO-1", .statusChanged, at: 1),
        event("DEMO-1", .statusChanged, at: 5),
        event("DEMO-2", .statusChanged, at: 3),
    ], revertWindowMinutes: 10)

    #expect(map["DEMO-1"] == base.addingTimeInterval(days(5)))
    #expect(map["DEMO-2"] == base.addingTimeInterval(days(3)))
}

/// 상태가 바뀌지 않은 변화는 진입 시각을 갱신하지 않는다. `touched`가 갱신하면
/// 댓글 한 줄로 정체일이 0으로 리셋되어, 이 앱이 재려는 것 자체가 사라진다.
@Test func ignoresEventsThatAreNotStatusChanges() {
    let map = StatusTimeline.latestStatusEntry(from: [
        event("DEMO-1", .statusChanged, at: 1),
        event("DEMO-1", .touched, at: 9),
        event("DEMO-1", .dueDateChanged, at: 9),
        event("DEMO-1", .appeared, at: 9),
        event("DEMO-1", .vanished, at: 9),
    ], revertWindowMinutes: 10)

    #expect(map["DEMO-1"] == base.addingTimeInterval(days(1)))
}

/// 이벤트 로그가 시간순이라는 보장은 없다. `ArcadeStore.loadEvents()`의 정렬은
/// 계약이 아니고, 백필은 과거 이벤트를 나중에 넣는다.
@Test func doesNotDependOnInputOrder() {
    let scrambled = [
        event("DEMO-1", .statusChanged, at: 5),
        event("DEMO-1", .statusChanged, at: 1),
        event("DEMO-1", .statusChanged, at: 3),
    ]

    #expect(StatusTimeline.latestStatusEntry(from: scrambled, revertWindowMinutes: 10)["DEMO-1"]
            == base.addingTimeInterval(days(5)))
}

@Test func hasNoEntryForIssuesThatNeverChangedStatus() {
    let map = StatusTimeline.latestStatusEntry(
        from: [event("DEMO-1", .appeared, at: 1)], revertWindowMinutes: 10
    )

    #expect(map["DEMO-1"] == nil)
}

@Test func handlesAnEmptyLog() {
    #expect(StatusTimeline.latestStatusEntry(from: [], revertWindowMinutes: 10).isEmpty)
}

/// `ScoreEngine`이 순회 도중 부르는 형태. 이 함수가 갱신 규칙의 유일한 정의다.
@Test func applyUpdatesOnlyOnStatusChange() {
    var map: [String: Date] = [:]

    StatusTimeline.apply(event("DEMO-1", .touched, at: 1), isReverted: false, to: &map)
    #expect(map.isEmpty)

    StatusTimeline.apply(event("DEMO-1", .statusChanged, at: 2), isReverted: false, to: &map)
    #expect(map["DEMO-1"] == base.addingTimeInterval(days(2)))
}

/// 되돌림 쌍은 `apply` 안에서 막힌다. 호출자가 가드를 빼먹어서 통과하는 일이 없어야 한다.
@Test func applyRefusesARevertedEvent() {
    var map: [String: Date] = [:]

    StatusTimeline.apply(event("DEMO-1", .statusChanged, at: 2), isReverted: true, to: &map)

    #expect(map.isEmpty)
}

/// 같은 상태로 다시 들어간 이벤트도 `apply` 안에서 막힌다. 백필(`ChangelogParser`)이
/// 이런 이벤트를 거르지 않아 실제 로그에 남는다.
@Test func applyRefusesANoOpTransition() {
    var map: [String: Date] = [:]
    let noOp = DomainEvent(
        issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "진행 중", toStatus: "진행 중",
        observedAt: base.addingTimeInterval(days(2)), actorAccountId: "acc-me"
    )

    StatusTimeline.apply(noOp, isReverted: false, to: &map)

    #expect(map.isEmpty)
}

/// 잘못 눌러 즉시 되돌린 티켓은 정체일을 잃지 않는다.
///
/// 채점은 이미 그 쌍을 0점으로 만든다. 시간축이 같은 판정을 쓰지 않으면 한 쌍을 두 층이
/// 다르게 보게 되고, 그것이 "XP는 막혔는데 정체일은 리셋된다"는 증상이었다.
@Test func aRevertPairDoesNotMoveTheBaseline() {
    let events = [
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "대기", toStatus: "진행 중",
                    observedAt: iso("2026-08-01T09:00:00Z"), actorAccountId: "acc-me"),
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "진행 중", toStatus: "검토",
                    observedAt: iso("2026-08-20T09:00:00Z"), actorAccountId: "acc-me"),
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "검토", toStatus: "진행 중",
                    observedAt: iso("2026-08-20T09:03:00Z"), actorAccountId: "acc-me"),
    ]

    let map = StatusTimeline.latestStatusEntry(from: events, revertWindowMinutes: 10)

    #expect(map["DEMO-1"] == iso("2026-08-01T09:00:00Z"))
}

/// 창 밖의 복귀는 기준선을 민다. 리뷰 반려 후 재작업은 진짜 움직임이다.
@Test func aReturnOutsideTheWindowStillMovesTheBaseline() {
    let events = [
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "대기", toStatus: "진행 중",
                    observedAt: iso("2026-08-01T09:00:00Z"), actorAccountId: "acc-me"),
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "진행 중", toStatus: "검토",
                    observedAt: iso("2026-08-20T09:00:00Z"), actorAccountId: "acc-me"),
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "검토", toStatus: "진행 중",
                    observedAt: iso("2026-08-20T13:00:00Z"), actorAccountId: "acc-me"),
    ]

    let map = StatusTimeline.latestStatusEntry(from: events, revertWindowMinutes: 10)

    #expect(map["DEMO-1"] == iso("2026-08-20T13:00:00Z"))
}

/// 백필은 라이브 동기화(`DiffEngine`)와 달리 같은 상태로의 전환(no-op)을 거르지 않는다.
/// 그런 이벤트가 기준선을 밀면, 실제로 아무 데도 가지 않은 티켓의 정체일이 리셋된다 —
/// 되돌림 쌍이 일으키던 것과 같은 증상이 다른 경로로 들어온 것이다.
@Test func aNoOpTransitionDoesNotMoveTheBaseline() {
    let events = [
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "대기", toStatus: "진행 중",
                    observedAt: iso("2026-08-01T09:00:00Z"), actorAccountId: "acc-me"),
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "진행 중", toStatus: "진행 중",
                    observedAt: iso("2026-08-20T09:00:00Z"), actorAccountId: "acc-me"),
    ]

    let map = StatusTimeline.latestStatusEntry(from: events, revertWindowMinutes: 10)

    #expect(map["DEMO-1"] == iso("2026-08-01T09:00:00Z"))
}
