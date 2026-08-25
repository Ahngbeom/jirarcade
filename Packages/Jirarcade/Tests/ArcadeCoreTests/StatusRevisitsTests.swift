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
///
/// **픽스처가 순서에 비대칭이어야 한다.** 두 건짜리 A→B / B→A는 뒤집어도 답이 1이라
/// 정렬이 없어도 통과한다. 여기서는 한 번도 돌아온 적 없는 티켓을 쓴다 — 정렬이 없으면
/// 집합이 `검토`로 열려 세 번째 이벤트가 `검토`로 "돌아온" 것으로 세어지고, 오조작 하나
/// 없는 티켓에 `⇄1`이 붙는다.
@Test func doesNotTrustInputOrder() {
    // 시간순: 대기→진행 중, 진행 중→검토, 검토→완료. 돌아온 적이 없다.
    let backfilled = [
        change("DEMO-1", from: "검토", to: "완료", at: "2026-08-09T09:00:00Z"),
        change("DEMO-1", from: "대기", to: "진행 중", at: "2026-08-01T09:00:00Z"),
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-05T09:00:00Z"),
    ]

    #expect(StatusRevisits.counts(from: backfilled, revertWindowMinutes: 10)["DEMO-1"] == nil)
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

/// 같은 상태로의 전환은 움직임이 아니다. 백필이 필터하지 않은 오류 데이터를 처리한다.
@Test func noOpTransitionAsOnlyEventIsAbsentFromTheMap() {
    let counts = StatusRevisits.counts(from: [
        change("DEMO-9", from: "진행 중", to: "진행 중", at: "2026-08-01T09:00:00Z"),
    ], revertWindowMinutes: 10)

    #expect(counts["DEMO-9"] == nil)
}

/// 같은 상태로의 전환은 움직임이 아니다. 중간에 끼어있는 오류 데이터를 처리한다.
@Test func noOpTransitionMidstreamIsIgnored() {
    let counts = StatusRevisits.counts(from: [
        change("DEMO-9", from: "대기", to: "진행 중", at: "2026-08-01T09:00:00Z"),
        change("DEMO-9", from: "진행 중", to: "진행 중", at: "2026-08-02T09:00:00Z"),
        change("DEMO-9", from: "진행 중", to: "검토", at: "2026-08-03T09:00:00Z"),
    ], revertWindowMinutes: 10)

    #expect(counts["DEMO-9"] == nil)
}
