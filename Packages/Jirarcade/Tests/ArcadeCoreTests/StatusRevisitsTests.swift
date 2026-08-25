import Testing
import Foundation
@testable import ArcadeCore

private func change(
    _ key: String, from: String, to: String, at: String
) -> DomainEvent {
    DomainEvent(issueKey: key, kind: .statusChanged, fromStatus: from, toStatus: to,
                observedAt: iso(at), actorAccountId: "acc-me")
}

/// 한 번도 돌아오지 않은 티켓은 맵에 없다. 0은 아무것도 말하지 않는다.
@Test func aTicketThatNeverReturnsIsAbsentFromTheMap() {
    let counts = StatusRevisits.counts(from: [
        change("DEMO-1", from: "대기", to: "진행 중", at: "2026-08-01T09:00:00Z"),
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-05T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "완료", at: "2026-08-09T09:00:00Z"),
    ], revertWindowMinutes: 10)

    #expect(counts["DEMO-1"] == nil)
}

/// 진행 중 → 검토 → 진행 중 → 검토 는 두 번 돌아온 것이다.
@Test func countsEachReturnToAStatusAlreadyVisited() {
    let counts = StatusRevisits.counts(from: [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-01T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-05T09:00:00Z"),
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-09T09:00:00Z"),
    ], revertWindowMinutes: 10)

    #expect(counts["DEMO-1"] == 2)
}

/// **오조작은 낙인이 아니다.** 창 안의 되돌림 쌍은 돌아온 것으로 세지 않는다.
@Test func aRevertInsideTheWindowDoesNotCountAsAReturn() {
    let counts = StatusRevisits.counts(from: [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-01T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-01T09:03:00Z"),
    ], revertWindowMinutes: 10)

    #expect(counts["DEMO-1"] == nil)
}

/// 창 밖의 복귀는 센다. 리뷰 반려로 돌아온 것은 진짜 움직임이다.
@Test func aReturnOutsideTheWindowCounts() {
    let counts = StatusRevisits.counts(from: [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-01T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-01T11:00:00Z"),
    ], revertWindowMinutes: 10)

    #expect(counts["DEMO-1"] == 1)
}

/// 티켓마다 따로 센다.
@Test func countsPerIssueIndependently() {
    let counts = StatusRevisits.counts(from: [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-01T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-05T09:00:00Z"),
        change("DEMO-2", from: "대기", to: "진행 중", at: "2026-08-02T09:00:00Z"),
    ], revertWindowMinutes: 10)

    #expect(counts["DEMO-1"] == 1)
    #expect(counts["DEMO-2"] == nil)
}

/// 입력이 시간순이 아니어도 결과가 같다. 백필은 과거 이벤트를 나중에 넣는다.
@Test func doesNotTrustInputOrder() {
    let shuffled = [
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-05T09:00:00Z"),
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-01T09:00:00Z"),
    ]

    #expect(StatusRevisits.counts(from: shuffled, revertWindowMinutes: 10)["DEMO-1"] == 1)
}

/// 상태를 모르는 이벤트는 건너뛴다 — 거쳤는지 판정할 수 없다.
@Test func skipsEventsWithoutStatuses() {
    let counts = StatusRevisits.counts(from: [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-01T09:00:00Z"),
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: nil, toStatus: nil,
                    observedAt: iso("2026-08-03T09:00:00Z"), actorAccountId: nil),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-05T09:00:00Z"),
    ], revertWindowMinutes: 10)

    #expect(counts["DEMO-1"] == 1)
}

/// 상태 변화가 아닌 이벤트는 세지 않는다.
@Test func ignoresNonStatusEvents() {
    let counts = StatusRevisits.counts(from: [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-01T09:00:00Z"),
        DomainEvent(issueKey: "DEMO-1", kind: .touched, fromStatus: nil, toStatus: nil,
                    observedAt: iso("2026-08-03T09:00:00Z"), actorAccountId: nil),
    ], revertWindowMinutes: 10)

    #expect(counts["DEMO-1"] == nil)
}
