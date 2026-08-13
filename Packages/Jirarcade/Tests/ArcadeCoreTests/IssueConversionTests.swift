import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

@Test func convertsEveryFieldFromTheDTO() {
    let due = iso("2026-08-14T00:00:00Z")
    let updated = iso("2026-08-12T06:04:05Z")
    let dto = JiraIssue(
        key: "DEMO-9613", summary: "버튼 추가", statusName: "In Progress", issueType: "개선",
        priority: "Medium", assigneeAccountId: "acc-me", assigneeName: "bahn",
        dueDate: due, updated: updated
    )

    let observed = ObservedIssue(dto)

    #expect(observed.key == "DEMO-9613")
    #expect(observed.summary == "버튼 추가")
    #expect(observed.statusName == "In Progress")
    #expect(observed.issueType == "개선")
    #expect(observed.priority == "Medium")
    #expect(observed.assigneeAccountId == "acc-me")
    #expect(observed.assigneeName == "bahn")
    #expect(observed.dueDate == due)
    #expect(observed.jiraUpdatedAt == updated)
}

@Test func optionalFieldsSurviveAsNil() {
    let dto = JiraIssue(
        key: "DEMO-1", summary: "무담당", statusName: "To Do", issueType: "버그",
        priority: nil, assigneeAccountId: nil, assigneeName: nil,
        dueDate: nil, updated: iso("2026-08-12T00:00:00Z")
    )
    let observed = ObservedIssue(dto)
    #expect(observed.priority == nil)
    #expect(observed.assigneeAccountId == nil)
    #expect(observed.dueDate == nil)
}
