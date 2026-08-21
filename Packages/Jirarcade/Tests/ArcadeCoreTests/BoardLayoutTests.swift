import Testing
import Foundation
@testable import ArcadeCore

private let now = iso("2026-08-21T00:00:00Z")

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func snapshot(
    _ issues: [ObservedIssue],
    enteredAt: [String: Date] = [:],
    workflow: WorkflowMap = demoWorkflow,
    spacing: Double = 0
) -> BoardSnapshot {
    BoardLayout.snapshot(
        issues: issues, statusEnteredAt: enteredAt, workflow: workflow,
        rules: .default, minimumSpacing: spacing, now: now, calendar: utc
    )
}

/// `done`은 레인에 넣지 않는다. 동기화 JQL이 `statusCategory != Done`이라 미러에
/// 완료 티켓이 없고, 영구히 빈 레인은 "뭔가 들어와야 하는데 비어 있다"는 잘못된 신호다.
@Test func laysOutTheFourVisibleStagesAndNotDone() {
    let result = snapshot([])

    #expect(result.lanes.map(\.stage) == [.backlog, .active, .review, .verify])
}

@Test func putsEachIssueInItsMappedStage() {
    let result = snapshot([
        issue(key: "DEMO-1", status: "To Do"),
        issue(key: "DEMO-2", status: "In Progress"),
        issue(key: "DEMO-3", status: "In Review"),
    ])

    #expect(result.lanes[0].slots.map(\.issue.key) == ["DEMO-1"])
    #expect(result.lanes[1].slots.map(\.issue.key) == ["DEMO-2"])
    #expect(result.lanes[2].slots.map(\.issue.key) == ["DEMO-3"])
}

/// 완료 상태의 티켓이 미러에 남아 있어도(재할당 직전 등) 레인에는 나타나지 않는다.
@Test func dropsIssuesInTheDoneStage() {
    let result = snapshot([issue(key: "DEMO-1", status: "Done")])

    #expect(result.lanes.allSatisfy { $0.slots.isEmpty })
    #expect(result.unmappedIssues.isEmpty)
}

/// 매핑되지 않은 상태의 티켓은 어느 레인에도 들어가지 못한다. 그대로 버리면
/// 보드에서 조용히 사라지고 사용자는 티켓이 없어졌다고 생각한다.
@Test func collectsIssuesWhoseStatusIsNotMapped() {
    let result = snapshot([
        issue(key: "DEMO-9", status: "Blocked"),
        issue(key: "DEMO-1", status: "In Progress"),
    ])

    #expect(result.unmappedIssues.map(\.key) == ["DEMO-9"])
    #expect(result.lanes[1].slots.map(\.issue.key) == ["DEMO-1"])
}

/// 미러는 딕셔너리에서 오므로 입력 순서가 불안정하다. 정렬하지 않으면 매 렌더마다
/// 목록 순서가 뒤바뀐다.
@Test func sortsUnmappedIssuesDeterministically() {
    let result = snapshot([
        issue(key: "DEMO-9", status: "Blocked"),
        issue(key: "DEMO-2", status: "Blocked"),
        issue(key: "DEMO-5", status: "Blocked"),
    ])

    #expect(result.unmappedIssues.map(\.key) == ["DEMO-2", "DEMO-5", "DEMO-9"])
}

@Test func usesStatusEnteredAtForStagnationWhenAvailable() {
    let result = snapshot(
        [issue(key: "DEMO-1", status: "In Progress",
               updated: now.addingTimeInterval(-days(1)))],
        enteredAt: ["DEMO-1": now.addingTimeInterval(-days(30))]
    )

    let slot = result.lanes[1].slots[0]
    #expect(slot.daysStagnant == 30)
    // RuleSet.default: bossDays 21, raidDays 45 (Task 1/StagnationTests.classifiesAtBoundaries).
    // 30일은 21≤x<45 구간이므로 .boss다.
    #expect(slot.tier == .boss)
    #expect(slot.isApproximate == false)
}

/// 관측 이력이 없으면 `jiraUpdatedAt`으로 폴백하되 그 사실을 표시한다. 근사값을
/// 확정처럼 보여주면 "관측한 것만 안다"는 이 앱의 원칙이 화면에서 깨진다.
@Test func marksStagnationAsApproximateWithoutHistory() {
    let result = snapshot(
        [issue(key: "DEMO-1", status: "In Progress",
               updated: now.addingTimeInterval(-days(9)))]
    )

    let slot = result.lanes[1].slots[0]
    #expect(slot.daysStagnant == 9)
    #expect(slot.tier == .stale)
    #expect(slot.isApproximate == true)
}

@Test func placesSlotsOnTheAxisByStagnation() {
    let result = snapshot(
        [issue(key: "DEMO-1", status: "In Progress")],
        enteredAt: ["DEMO-1": now.addingTimeInterval(-days(21))]
    )

    #expect(abs(result.lanes[1].slots[0].position - 2.0 / 3) < 0.0001)
}

@Test func reportsNoDueStateWithoutADueDate() {
    let result = snapshot([issue(key: "DEMO-1", status: "In Progress")])

    #expect(result.lanes[1].slots[0].dueState == DueState.none)
}

/// 마감 당일은 아직 지나지 않은 것으로 본다(`DueDate.isOverdue`와 같은 규칙).
@Test func countsTheDueDayItselfAsRemaining() {
    let result = snapshot([issue(key: "DEMO-1", status: "In Progress", due: now)])

    #expect(result.lanes[1].slots[0].dueState == DueState.dueIn(days: 0))
}

@Test func reportsDaysRemainingAndOverdue() {
    let soon = snapshot([
        issue(key: "DEMO-1", status: "In Progress", due: now.addingTimeInterval(days(3)))
    ])
    let late = snapshot([
        issue(key: "DEMO-2", status: "In Progress", due: now.addingTimeInterval(-days(2)))
    ])

    #expect(soon.lanes[1].slots[0].dueState == DueState.dueIn(days: 3))
    #expect(late.lanes[1].slots[0].dueState == DueState.overdue(days: 2))
}

@Test func carriesTheAxisInTheSnapshot() {
    #expect(snapshot([]).axis.map(\.days) == [0, 7, 21, 45])
}
