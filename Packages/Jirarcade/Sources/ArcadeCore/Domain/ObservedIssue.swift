import Foundation
import JiraKit

/// 규칙 엔진이 다루는 티켓의 값 표현. SwiftData나 네트워크 타입에 의존하지 않는다.
public struct ObservedIssue: Sendable, Equatable, Identifiable {
    public var id: String { key }

    public let key: String
    public let summary: String
    public let statusName: String
    public let issueType: String
    public let priority: String?
    public let assigneeAccountId: String?
    public let assigneeName: String?
    public let dueDate: Date?
    public let jiraUpdatedAt: Date

    public init(
        key: String, summary: String, statusName: String, issueType: String,
        priority: String?, assigneeAccountId: String?, assigneeName: String?,
        dueDate: Date?, jiraUpdatedAt: Date
    ) {
        self.key = key
        self.summary = summary
        self.statusName = statusName
        self.issueType = issueType
        self.priority = priority
        self.assigneeAccountId = assigneeAccountId
        self.assigneeName = assigneeName
        self.dueDate = dueDate
        self.jiraUpdatedAt = jiraUpdatedAt
    }
}

extension ObservedIssue {
    /// JiraKit DTO를 규칙 엔진이 쓰는 값 타입으로 옮긴다.
    /// 상태명은 조직 커스텀 값 그대로 보존하며 여기서 단계로 바꾸지 않는다.
    public init(_ jira: JiraIssue) {
        self.init(
            key: jira.key,
            summary: jira.summary,
            statusName: jira.statusName,
            issueType: jira.issueType,
            priority: jira.priority,
            assigneeAccountId: jira.assigneeAccountId,
            assigneeName: jira.assigneeName,
            dueDate: jira.dueDate,
            jiraUpdatedAt: jira.updated
        )
    }
}
