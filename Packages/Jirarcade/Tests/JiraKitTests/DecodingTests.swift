import Testing
import Foundation
@testable import JiraKit

private func json(_ text: String) -> Data { Data(text.utf8) }

private let goodIssue = """
{
  "key": "DEMO-9613",
  "fields": {
    "summary": "[통합/태블릿] 화면 A에서 버튼 추가",
    "status": { "name": "In Progress" },
    "issuetype": { "name": "개선" },
    "priority": { "name": "Medium" },
    "assignee": { "accountId": "acc-me", "displayName": "bahn" },
    "duedate": "2026-08-14",
    "updated": "2026-08-12T15:04:05.000+0900"
  }
}
"""

@Test func decodesARealisticIssue() throws {
    let page = try JiraSearchResponse.decode(json("""
    { "issues": [\(goodIssue)] }
    """))
    #expect(page.issues.count == 1)
    let issue = page.issues[0]
    #expect(issue.key == "DEMO-9613")
    #expect(issue.statusName == "In Progress")
    #expect(issue.issueType == "개선")
    #expect(issue.assigneeName == "bahn")
    #expect(issue.dueDate != nil)
}

@Test func nullAssigneeAndMissingDueDateAreTolerated() throws {
    let page = try JiraSearchResponse.decode(json("""
    { "issues": [{
        "key": "DEMO-1",
        "fields": {
          "summary": "담당자 없음",
          "status": { "name": "To Do" },
          "issuetype": { "name": "버그" },
          "priority": null,
          "assignee": null,
          "updated": "2026-08-12T15:04:05.000+0900"
        }
    }] }
    """))
    #expect(page.issues.count == 1)
    #expect(page.issues[0].assigneeAccountId == nil)
    #expect(page.issues[0].dueDate == nil)
    #expect(page.issues[0].priority == nil)
}

@Test func oneBrokenIssueDoesNotDiscardTheOthers() throws {
    let broken = """
    { "key": "DEMO-BAD", "fields": { "summary": "상태 필드가 없음" } }
    """
    let page = try JiraSearchResponse.decode(json("""
    { "issues": [\(goodIssue), \(broken), \(goodIssue)] }
    """))
    #expect(page.issues.count == 2)
    #expect(page.failures.count == 1)
}

@Test func nextPageTokenIsCarriedThrough() throws {
    let page = try JiraSearchResponse.decode(json("""
    { "issues": [], "nextPageToken": "tok-2" }
    """))
    #expect(page.nextPageToken == "tok-2")
}

@Test func jiraTimestampsParseWithMillisecondsAndOffset() throws {
    let page = try JiraSearchResponse.decode(json("{ \"issues\": [\(goodIssue)] }"))
    let expected = ISO8601DateFormatter().date(from: "2026-08-12T06:04:05Z")!
    #expect(abs(page.issues[0].updated.timeIntervalSince(expected)) < 1)
}

/// 소수점 초가 없는 `updated`는 실제로 관측되는 변형인데, `.withFractionalSeconds`만
/// 켠 포매터는 여기서 nil을 돌려준다. 이슈 단위로 삼켜지므로 예외 없이 전량 손실이 된다.
@Test(arguments: [
    ("2026-08-12T15:04:05+0900", "2026-08-12T06:04:05Z"),
    ("2026-08-12T15:04:05+09:00", "2026-08-12T06:04:05Z"),
    ("2026-08-12T06:04:05Z", "2026-08-12T06:04:05Z"),
    ("2026-08-12T06:04:05.000Z", "2026-08-12T06:04:05Z"),
    ("2026-08-12T15:04:05.000+09:00", "2026-08-12T06:04:05Z"),
])
func timestampsParseWithOrWithoutFractionalSeconds(raw: String, expected: String) throws {
    let page = try JiraSearchResponse.decode(json("""
    { "issues": [{
        "key": "DEMO-1",
        "fields": {
          "summary": "시각 형식 변형",
          "status": { "name": "In Progress" },
          "issuetype": { "name": "개선" },
          "updated": "\(raw)"
        }
    }] }
    """))

    #expect(page.failures.isEmpty, "\(raw) 파싱 실패")
    let target = ISO8601DateFormatter().date(from: expected)!
    #expect(abs(try #require(page.issues.first).updated.timeIntervalSince(target)) < 1)
}

@Test func malformedTopLevelJSONThrows() {
    #expect(throws: (any Error).self) {
        try JiraSearchResponse.decode(json("not json at all"))
    }
}

/// 도착 상태를 싣지 않는 전이가 섞여도 나머지는 살아남는다.
///
/// `to`가 없는 전이는 Jira에 실제로 존재한다 — 화면이 붙은 전이 중 도착 상태를 응답에
/// 싣지 않는 구성, 일부 전역 전이, 권한에 따라 도착 상태가 가려지는 경우.
///
/// 하나가 배열 전체를 무너뜨리면 카드의 메뉴가 "옮길 수 있는 상태가 없습니다"를 띄우고
/// 사용자는 그 티켓을 앱에서 아예 옮길 수 없다. 그게 사실이 아닌데도.
@Test func aTransitionWithoutADestinationDoesNotDropTheOthers() throws {
    let transitions = try JiraTransition.decodeList(json("""
    { "transitions": [
        { "id": "11", "name": "시작", "to": { "name": "진행 중" } },
        { "id": "12", "name": "도착지 없음", "to": null },
        { "id": "13", "name": "완료로", "to": { "name": "완료" } }
    ] }
    """))

    #expect(transitions.count == 2)
    #expect(transitions.map(\.id) == ["11", "13"])
    #expect(transitions[1].toStatusName == "완료")
}

/// 필수 필드가 통째로 빠진 항목도 자기만 떨어진다.
@Test func aTransitionMissingItsNameDoesNotDropTheOthers() throws {
    let transitions = try JiraTransition.decodeList(json("""
    { "transitions": [
        { "id": "21", "to": { "name": "검토" } },
        { "id": "22", "name": "완료로", "to": { "name": "완료" } }
    ] }
    """))

    #expect(transitions.map(\.id) == ["22"])
}

@Test func transitionsDecode() throws {
    let transitions = try JiraTransition.decodeList(json("""
    { "transitions": [
        { "id": "21", "name": "In Review", "to": { "name": "In Review" } }
    ] }
    """))
    #expect(transitions.count == 1)
    #expect(transitions[0].id == "21")
    #expect(transitions[0].toStatusName == "In Review")
}
