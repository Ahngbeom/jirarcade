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
    ])

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
    ])

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

    #expect(StatusTimeline.latestStatusEntry(from: scrambled)["DEMO-1"]
            == base.addingTimeInterval(days(5)))
}

@Test func hasNoEntryForIssuesThatNeverChangedStatus() {
    let map = StatusTimeline.latestStatusEntry(from: [event("DEMO-1", .appeared, at: 1)])

    #expect(map["DEMO-1"] == nil)
}

@Test func handlesAnEmptyLog() {
    #expect(StatusTimeline.latestStatusEntry(from: []).isEmpty)
}

/// `ScoreEngine`이 순회 도중 부르는 형태. 이 함수가 규칙의 유일한 정의다.
@Test func applyUpdatesOnlyOnStatusChange() {
    var map: [String: Date] = [:]

    StatusTimeline.apply(event("DEMO-1", .touched, at: 1), to: &map)
    #expect(map.isEmpty)

    StatusTimeline.apply(event("DEMO-1", .statusChanged, at: 2), to: &map)
    #expect(map["DEMO-1"] == base.addingTimeInterval(days(2)))
}
