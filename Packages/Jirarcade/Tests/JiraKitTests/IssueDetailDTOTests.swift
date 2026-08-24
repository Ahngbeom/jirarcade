import Testing
import Foundation
@testable import JiraKit

@Test func readsKeySummaryAndDescription() throws {
    let json = #"""
    {"key":"DEMO-1","fields":{"summary":"제목","description":{"type":"doc","content":[
      {"type":"paragraph","content":[{"type":"text","text":"본문"}]}
    ]}}}
    """#

    let detail = try JiraIssueDetail.decode(Data(json.utf8))

    #expect(detail.key == "DEMO-1")
    #expect(detail.summary == "제목")
    #expect(detail.description?.content.count == 1)
}

/// 본문이 비어 있는 티켓은 흔하다. description이 null이라고 상세가 통째로
/// 실패하면 제목도 댓글도 못 본다.
@Test func aNullDescriptionIsNotAFailure() throws {
    let json = #"{"key":"DEMO-2","fields":{"summary":"제목만","description":null}}"#

    let detail = try JiraIssueDetail.decode(Data(json.utf8))

    #expect(detail.summary == "제목만")
    #expect(detail.description == nil)
}

@Test func readsCommentsWithAuthorAndTime() throws {
    let json = #"""
    {"comments":[
      {"id":"10","author":{"displayName":"어떤 사람"},"created":"2026-08-24T09:00:00.000+0900",
       "body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"댓글"}]}]}}
    ]}
    """#

    let comments = try JiraComment.decodePage(Data(json.utf8))

    #expect(comments.count == 1)
    #expect(comments[0].id == "10")
    #expect(comments[0].authorName == "어떤 사람")
    #expect(comments[0].body?.content.count == 1)
}

/// 댓글 하나가 이상해도 나머지는 보여야 한다. 한 건 때문에 대화 전체가
/// 사라지면 "지금 무슨 상황인가"를 판단할 수 없다.
@Test func oneBrokenCommentDoesNotDropThePage() throws {
    let json = #"""
    {"comments":[
      {"id":"10","author":{"displayName":"정상"},"created":"2026-08-24T09:00:00.000+0900","body":null},
      {"author":{"displayName":"id 없음"},"created":"2026-08-24T09:05:00.000+0900","body":null}
    ]}
    """#

    let comments = try JiraComment.decodePage(Data(json.utf8))

    #expect(comments.count == 1)
    #expect(comments[0].authorName == "정상")
}

/// 작성자 이름이 빠지는 경우가 있다(삭제된 계정, 앱 사용자). 이름이 없다고
/// 댓글을 버리지 않는다.
@Test func aMissingAuthorNameFallsBack() throws {
    let json = #"""
    {"comments":[
      {"id":"11","created":"2026-08-24T09:00:00.000+0900","body":null}
    ]}
    """#

    let comments = try JiraComment.decodePage(Data(json.utf8))

    #expect(comments.count == 1)
    #expect(comments[0].authorName == "알 수 없음")
}

/// 본문이 구조적으로 잘못된 댓글도 살린다 — id와 시간은 있는데 본문만 이상해도
/// 대화에서 없어지면 안 된다. 본문이 nil이어도 "누가 이 시간에 뭔가 했다"는
/// 기록은 남는다.
@Test func anInvalidBodyDoesNotDropTheComment() throws {
    let json = #"""
    {"comments":[
      {"id":"12","author":{"displayName":"유효한"},"created":"2026-08-24T09:00:00.000+0900","body":{"notype":"oops"}},
      {"id":"13","author":{"displayName":"정상"},"created":"2026-08-24T09:10:00.000+0900","body":null}
    ]}
    """#

    let comments = try JiraComment.decodePage(Data(json.utf8))

    #expect(comments.count == 2)
    #expect(comments[0].id == "12")
    #expect(comments[0].authorName == "유효한")
    #expect(comments[0].body == nil)
    #expect(comments[1].id == "13")
}

/// 상세 본문이 구조적으로 잘못된 티켓도 제목은 살린다 — 구조가 깨진 본문 때문에
/// 상세 전체가 실패하면 제목도 못 보고 댓글도 못 본다.
@Test func anInvalidDescriptionDoesNotDropTheSummary() throws {
    let json = #"""
    {"key":"DEMO-9","fields":{"summary":"제목은 멀쩡함","description":{"notype":"oops"}}}
    """#

    let detail = try JiraIssueDetail.decode(Data(json.utf8))

    #expect(detail.key == "DEMO-9")
    #expect(detail.summary == "제목은 멀쩡함")
    #expect(detail.description == nil)
}
