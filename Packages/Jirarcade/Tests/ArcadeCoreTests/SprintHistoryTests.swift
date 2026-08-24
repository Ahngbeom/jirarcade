import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

private func sprint(_ id: Int, _ name: String, day: Int?, state: String = "closed") -> JiraSprint {
    JiraSprint(
        id: id, name: name, state: state,
        startDate: day.map { iso("2026-05-\(String(format: "%02d", $0))T10:00:00Z") }
    )
}

/// 실측에서 배열이 [56, 57, 55, 64, 63, 52, 65, ...] 순으로 왔다.
/// startDate로 정렬하지 않으면 양 끝 이름이 엉뚱해진다.
@Test func sortsByStartDateBecauseTheArrayArrivesShuffled() {
    let summary = SprintHistory.summarize([
        sprint(2, "DEMO 스프린트 (2)", day: 21),
        sprint(3, "DEMO 스프린트 (3)", day: 28),
        sprint(1, "DEMO 스프린트 (1)", day: 14),
    ])

    #expect(summary.firstName == "DEMO 스프린트 (1)")
    #expect(summary.latestName == "DEMO 스프린트 (3)")
}

/// 첫 스프린트는 이월이 아니다. 3개에 속했으면 2번 미뤄진 것이다.
@Test func countsCarryOversAsSprintsMinusOne() {
    let summary = SprintHistory.summarize([
        sprint(1, "DEMO 스프린트 (1)", day: 14),
        sprint(2, "DEMO 스프린트 (2)", day: 21),
        sprint(3, "DEMO 스프린트 (3)", day: 28),
    ])

    #expect(summary.carryOvers == 2)
}

@Test func reportsZeroForASingleSprint() {
    let summary = SprintHistory.summarize([sprint(1, "DEMO 스프린트 (1)", day: 14)])

    #expect(summary.carryOvers == 0)
    #expect(summary.firstName == "DEMO 스프린트 (1)")
    #expect(summary.latestName == "DEMO 스프린트 (1)")
}

@Test func reportsNothingForNoSprints() {
    let summary = SprintHistory.summarize([])

    #expect(summary.carryOvers == 0)
    #expect(summary.firstName == nil)
    #expect(summary.latestName == nil)
}

/// `startDate`가 없는 스프린트는 정렬에서 맨 뒤로 보내되 **횟수에는 들어간다** —
/// 그 스프린트에 속했다는 사실은 날짜를 모른다고 사라지지 않는다.
@Test func keepsUndatedSprintsInTheCountAndSortsThemLast() {
    let summary = SprintHistory.summarize([
        sprint(9, "DEMO 스프린트 (9)", day: nil),
        sprint(1, "DEMO 스프린트 (1)", day: 14),
    ])

    #expect(summary.carryOvers == 1)
    #expect(summary.firstName == "DEMO 스프린트 (1)")
    #expect(summary.latestName == "DEMO 스프린트 (9)")
}

/// Swift의 `sorted(by:)`는 안정 정렬이 아니다. 같은 날 시작한 스프린트 둘이 있으면
/// 타이브레이크가 없을 때 툴팁이 실행마다 바뀐다.
@Test func breaksStartDateTiesByID() {
    let summary = SprintHistory.summarize([
        sprint(20, "DEMO 스프린트 (20)", day: 14),
        sprint(10, "DEMO 스프린트 (10)", day: 14),
    ])

    #expect(summary.firstName == "DEMO 스프린트 (10)")
    #expect(summary.latestName == "DEMO 스프린트 (20)")
}

/// 예정 스프린트도 이월로 센다 — 다음에 하기로 올려둔 것 역시 "아직 안 끝났다"이다.
@Test func countsFutureSprintsToo() {
    let summary = SprintHistory.summarize([
        sprint(1, "DEMO 스프린트 (1)", day: 14, state: "closed"),
        sprint(2, "DEMO 스프린트 (2)", day: 21, state: "future"),
    ])

    #expect(summary.carryOvers == 1)
}
