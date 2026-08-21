import Testing
import Foundation
@testable import ArcadeCore

private func slot(_ key: String, at position: Double) -> BoardSlot {
    BoardSlot(
        issue: issue(key: key, status: "In Progress"),
        daysStagnant: 0, tier: .fresh, position: position, row: 0,
        isApproximate: false, dueState: .none
    )
}

private func rows(_ packed: [BoardSlot]) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: packed.map { ($0.issue.key, $0.row) })
}

@Test func keepsDistantSlotsOnTheSameRow() {
    let packed = LanePacker.pack(
        [slot("DEMO-1", at: 0.0), slot("DEMO-2", at: 0.5)], minimumSpacing: 0.1
    )

    #expect(rows(packed) == ["DEMO-1": 0, "DEMO-2": 0])
}

@Test func stacksSlotsThatWouldOverlap() {
    let packed = LanePacker.pack(
        [slot("DEMO-1", at: 0.10), slot("DEMO-2", at: 0.12)], minimumSpacing: 0.1
    )

    #expect(rows(packed) == ["DEMO-1": 0, "DEMO-2": 1])
}

@Test func stacksThreeCrowdedSlotsOnSeparateRows() {
    let packed = LanePacker.pack(
        [slot("DEMO-1", at: 0.10), slot("DEMO-2", at: 0.11), slot("DEMO-3", at: 0.12)],
        minimumSpacing: 0.1
    )

    #expect(rows(packed) == ["DEMO-1": 0, "DEMO-2": 1, "DEMO-3": 2])
}

/// 가장 낮은 줄에 넣는다. 세 번째가 첫 번째에서 충분히 떨어졌으면 새 줄을 만들지 않고
/// 0번 줄로 돌아간다 — 그러지 않으면 레인이 필요 이상으로 높아진다.
@Test func reusesTheLowestRowThatHasSpace() {
    let packed = LanePacker.pack(
        [slot("DEMO-1", at: 0.10), slot("DEMO-2", at: 0.12), slot("DEMO-3", at: 0.40)],
        minimumSpacing: 0.1
    )

    #expect(rows(packed) == ["DEMO-1": 0, "DEMO-2": 1, "DEMO-3": 0])
}

/// Swift의 `sorted(by:)`는 안정 정렬이 아니다. 동률을 issueKey로 가르지 않으면 같은
/// 정체일 티켓 두 건의 상하 순서가 실행마다 뒤집혀 화면이 매 렌더 흔들린다.
@Test func breaksPositionTiesByIssueKey() {
    let packed = LanePacker.pack(
        [slot("DEMO-9", at: 0.3), slot("DEMO-2", at: 0.3), slot("DEMO-5", at: 0.3)],
        minimumSpacing: 0.1
    )

    #expect(rows(packed) == ["DEMO-2": 0, "DEMO-5": 1, "DEMO-9": 2])
}

@Test func returnsSlotsSortedByPosition() {
    let packed = LanePacker.pack(
        [slot("DEMO-3", at: 0.9), slot("DEMO-1", at: 0.1), slot("DEMO-2", at: 0.5)],
        minimumSpacing: 0.1
    )

    #expect(packed.map(\.issue.key) == ["DEMO-1", "DEMO-2", "DEMO-3"])
}

@Test func putsEverythingOnOneRowWhenNoSpacingIsRequired() {
    let packed = LanePacker.pack(
        [slot("DEMO-1", at: 0.1), slot("DEMO-2", at: 0.1)], minimumSpacing: 0
    )

    #expect(rows(packed) == ["DEMO-1": 0, "DEMO-2": 0])
}

@Test func handlesAnEmptyLane() {
    #expect(LanePacker.pack([], minimumSpacing: 0.1).isEmpty)
}
