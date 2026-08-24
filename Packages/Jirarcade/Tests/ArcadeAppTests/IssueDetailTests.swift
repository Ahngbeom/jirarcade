import Testing
import Foundation
@testable import ArcadeApp
@testable import ArcadeCore
import JiraKit

@MainActor
@Test func openingDetailLoadsSummaryDescriptionAndComments() async throws {
    let detailBody = #"""
    {"key":"DEMO-1","fields":{"summary":"제목","description":{"type":"doc","content":[
      {"type":"paragraph","content":[{"type":"text","text":"본문"}]}]}}}
    """#
    let commentBody = #"""
    {"comments":[{"id":"10","author":{"displayName":"어떤 사람"},
      "created":"2026-08-24T09:00:00.000+0900",
      "body":{"type":"doc","content":[{"type":"paragraph","content":[
        {"type":"text","text":"댓글"}]}]}}]}
    """#
    let model = try makeModel(http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            // 로그인 경로는 /myself 다음에 /field, 그다음 매핑 후보용 검색을 부른다
            // (workflow store가 비어 있으므로 routeAfterAuthentication이 매핑 마법사로
            // 간다). 둘 다 결과를 try?로 받아 실패해도 로그인을 막지 않으므로 본문은
            // 무관하고 응답 슬롯만 채우면 된다.
            .init(status: 200, body: Data("{}".utf8)),
            .init(status: 200, body: Data("{}".utf8)),
            .init(status: 200, body: Data(detailBody.utf8)),
            .init(status: 200, body: Data(commentBody.utf8)),
        ])
    })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")

    await model.openDetail(issueKey: "DEMO-1")

    guard case .loaded(let detail) = model.detailState else {
        Issue.record("상세가 로드되지 않았다: \(model.detailState)")
        return
    }
    #expect(detail.summary == "제목")
    #expect(detail.descriptionText == "본문")
    #expect(detail.comments.count == 1)
    #expect(detail.comments[0].text == "댓글")
}

/// Jira가 준 사유를 화면에 옮기지 않는다. 시트 조회는 동기화의 축약 경로 밖에서
/// 돌기 때문에 이 처리를 공짜로 얻지 못한다.
@MainActor
@Test func aFailedDetailFetchDoesNotQuoteJira() async throws {
    let rejected = #"{"errorMessages":["someone@example.com 님의 요청이 거부되었습니다: 사용자 정의 필드 XYZ 필요"]}"#
    let model = try makeModel(http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data("{}".utf8)),
            .init(status: 200, body: Data("{}".utf8)),
            .init(status: 400, body: Data(rejected.utf8)),
        ])
    })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")

    await model.openDetail(issueKey: "DEMO-1")

    guard case .failed(let message) = model.detailState else {
        Issue.record("실패 상태가 아니다: \(model.detailState)")
        return
    }
    #expect(!message.contains("someone@example.com"))
    #expect(!message.contains("XYZ"))
    #expect(!message.contains("거부되었습니다"))
}

/// 시트를 닫으면 받아온 것을 버린다. 남겨두면 다음에 다른 티켓을 열 때
/// 이전 티켓의 본문이 잠깐 보인다.
@MainActor
@Test func closingDetailForgetsWhatWasLoaded() async throws {
    let detailBody = #"{"key":"DEMO-1","fields":{"summary":"제목","description":null}}"#
    let model = try makeModel(http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data("{}".utf8)),
            .init(status: 200, body: Data("{}".utf8)),
            .init(status: 200, body: Data(detailBody.utf8)),
            .init(status: 200, body: Data(#"{"comments":[]}"#.utf8)),
        ])
    })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    await model.openDetail(issueKey: "DEMO-1")
    guard case .loaded = model.detailState else {
        Issue.record("먼저 로드되어야 한다: \(model.detailState)")
        return
    }

    model.closeDetail()

    #expect(model.detailState == .idle)
}
