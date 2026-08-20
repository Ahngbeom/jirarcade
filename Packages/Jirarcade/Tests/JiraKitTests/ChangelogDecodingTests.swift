import Testing
import Foundation
@testable import JiraKit

private let searchBody = """
{
  "issues": [{
    "key": "MPT-1647",
    "fields": {
      "created": "2022-12-30T10:05:20.812+0900",
      "duedate": "2023-03-10"
    },
    "changelog": {
      "startAt": 0, "maxResults": 10, "total": 2,
      "histories": [
        {
          "id": "50347",
          "created": "2023-02-28T10:15:06.939+0900",
          "author": { "accountId": "acc-me" },
          "items": [
            { "field": "status", "fieldId": "status",
              "from": "10009", "fromString": "To Do",
              "to": "10016", "toString": "In Progress" }
          ]
        },
        {
          "id": "50779",
          "created": "2023-03-02T12:13:52.874+0900",
          "author": { "accountId": "acc-other" },
          "items": [
            { "field": "description", "from": null, "fromString": "옛 본문",
              "to": null, "toString": "새 본문" },
            { "field": "status", "fieldId": "status",
              "from": "10016", "fromString": "In Progress",
              "to": "10071", "toString": "Merged to Staging" }
          ]
        }
      ]
    }
  }],
  "nextPageToken": "tok-2"
}
"""

@Test func decodesIssuesWithChangelog() throws {
    let (issues, token) = try JiraChangelogResponse.decodeSearch(Data(searchBody.utf8))
    #expect(token == "tok-2")
    #expect(issues.count == 1)

    let issue = try #require(issues.first)
    #expect(issue.key == "MPT-1647")
    #expect(issue.dueDate != nil)
    #expect(issue.changelog.histories.count == 2)
    #expect(issue.changelog.total == 2)
}

@Test func keepsAllItemsIncludingNonStatus() throws {
    // 걸러내는 일은 파서(ArcadeCore)가 한다. JiraKit은 응답을 있는 그대로 옮긴다.
    let (issues, _) = try JiraChangelogResponse.decodeSearch(Data(searchBody.utf8))
    let second = try #require(issues.first?.changelog.histories[safe: 1])
    #expect(second.items.count == 2)
    #expect(second.items.map(\.field).contains("description"))
}

@Test func exposesStatusIdsForCategoryFallback() throws {
    let (issues, _) = try JiraChangelogResponse.decodeSearch(Data(searchBody.utf8))
    let statusItem = try #require(
        issues.first?.changelog.histories.first?.items.first { $0.field == "status" }
    )
    #expect(statusItem.fromId == "10009")
    #expect(statusItem.toId == "10016")
    #expect(statusItem.fromString == "To Do")
    #expect(statusItem.toString == "In Progress")
}

@Test func authorAccountIdIsCarried() throws {
    let (issues, _) = try JiraChangelogResponse.decodeSearch(Data(searchBody.utf8))
    let first = try #require(issues.first?.changelog.histories[safe: 0])
    let second = try #require(issues.first?.changelog.histories[safe: 1])
    #expect(first.authorAccountId == "acc-me")
    #expect(second.authorAccountId == "acc-other")
}

/// total이 histories보다 크면 서버가 잘라 보낸 것이다. 이 신호를 놓치면
/// history가 많은 오래된 티켓의 전이가 조용히 누락된다(스펙 §7.1).
@Test func truncationIsDetected() throws {
    let body = """
    { "issues": [{
        "key": "MPT-1", "fields": { "created": "2023-01-01T00:00:00.000+0900" },
        "changelog": { "startAt": 0, "maxResults": 10, "total": 42, "histories": [] }
    }] }
    """
    let (issues, _) = try JiraChangelogResponse.decodeSearch(Data(body.utf8))
    let issue = try #require(issues.first)
    #expect(issue.changelog.isTruncated == true)
}

@Test func completeChangelogIsNotTruncated() throws {
    let (issues, _) = try JiraChangelogResponse.decodeSearch(Data(searchBody.utf8))
    let issue = try #require(issues.first)
    #expect(issue.changelog.isTruncated == false)
}

/// 담당자가 없거나 마감일이 없는 티켓도 있다.
@Test func missingOptionalFieldsAreTolerated() throws {
    let body = """
    { "issues": [{
        "key": "MPT-2", "fields": { "created": "2023-01-01T00:00:00.000+0900" },
        "changelog": { "startAt": 0, "maxResults": 10, "total": 1, "histories": [
          { "id": "1", "created": "2023-01-02T00:00:00.000+0900", "items": [] }
        ] }
    }] }
    """
    let (issues, _) = try JiraChangelogResponse.decodeSearch(Data(body.utf8))
    let issue = try #require(issues.first)
    #expect(issue.dueDate == nil)
    #expect(issue.changelog.histories[0].authorAccountId == nil)
}

@Test func decodesStandaloneIssueChangelog() throws {
    let body = """
    { "startAt": 0, "maxResults": 100, "total": 1, "values": [
        { "id": "99", "created": "2023-05-01T00:00:00.000+0900",
          "author": { "accountId": "acc-me" },
          "items": [{ "field": "status", "from": "1", "fromString": "A",
                      "to": "2", "toString": "B" }] }
    ] }
    """
    let page = try JiraChangelogResponse.decodeIssueChangelog(Data(body.utf8))
    #expect(page.histories.count == 1)
    let history = try #require(page.histories.first)
    #expect(history.id == "99")
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
