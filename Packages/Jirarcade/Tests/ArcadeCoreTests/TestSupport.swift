import Foundation
@testable import ArcadeCore

/// 테스트용 가상 워크플로. 실제 조직의 상태명을 저장소에 남기지 않기 위해
/// Jira에서 흔한 영문 상태명으로 구성했다.
let demoWorkflow = WorkflowMap(statusToStage: [
    "To Do": .backlog,
    "In Progress": .active,
    "In Review": .review,
    "Verifying": .verify,
    "Done": .done,
])

/// 테스트에서 고정 시각을 만든다. 실패 시 즉시 크래시시켜 잘못된 리터럴을 빨리 드러낸다.
func iso(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: string) else {
        fatalError("잘못된 ISO8601 리터럴: \(string)")
    }
    return date
}

func days(_ count: Double) -> TimeInterval { count * 86_400 }
func minutes(_ count: Double) -> TimeInterval { count * 60 }
func hours(_ count: Double) -> TimeInterval { count * 3_600 }

func issue(
    key: String,
    summary: String = "샘플 티켓",
    status: String,
    type: String = "개선",
    priority: String? = "Medium",
    assignee: String? = "acc-me",
    assigneeName: String? = "bahn",
    due: Date? = nil,
    updated: Date = iso("2026-08-12T00:00:00Z")
) -> ObservedIssue {
    ObservedIssue(
        key: key, summary: summary, statusName: status, issueType: type,
        priority: priority, assigneeAccountId: assignee, assigneeName: assigneeName,
        dueDate: due, jiraUpdatedAt: updated
    )
}
