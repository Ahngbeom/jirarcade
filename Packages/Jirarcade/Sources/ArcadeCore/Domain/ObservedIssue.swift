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
    /// 이 티켓이 거쳐 온 스프린트 수 - 1. 스프린트가 없거나 하나뿐이면 0이다.
    /// **채점에 쓰지 않는다** — 표시 전용이다.
    public let sprintCarryOvers: Int
    /// 가장 이른 스프린트 이름. 뷰가 "A → B" 문장을 만들 때 쓴다.
    public let firstSprintName: String?
    /// 가장 늦은 스프린트 이름.
    public let latestSprintName: String?

    public init(
        key: String, summary: String, statusName: String, issueType: String,
        priority: String?, assigneeAccountId: String?, assigneeName: String?,
        dueDate: Date?, jiraUpdatedAt: Date,
        sprintCarryOvers: Int = 0,
        firstSprintName: String? = nil,
        latestSprintName: String? = nil
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
        self.sprintCarryOvers = sprintCarryOvers
        self.firstSprintName = firstSprintName
        self.latestSprintName = latestSprintName
    }
}

extension ObservedIssue {
    /// JiraKit DTO를 규칙 엔진이 쓰는 값 타입으로 옮긴다.
    /// 상태명은 조직 커스텀 값 그대로 보존하며 여기서 단계로 바꾸지 않는다.
    public init(_ jira: JiraIssue) {
        let sprints = SprintHistory.summarize(jira.sprints)
        self.init(
            key: jira.key,
            summary: jira.summary,
            statusName: jira.statusName,
            issueType: jira.issueType,
            priority: jira.priority,
            assigneeAccountId: jira.assigneeAccountId,
            assigneeName: jira.assigneeName,
            dueDate: jira.dueDate,
            jiraUpdatedAt: jira.updated,
            sprintCarryOvers: sprints.carryOvers,
            firstSprintName: sprints.firstName,
            latestSprintName: sprints.latestName
        )
    }
}
