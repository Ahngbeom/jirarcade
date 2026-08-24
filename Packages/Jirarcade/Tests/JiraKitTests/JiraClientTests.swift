import Testing
import Foundation
@testable import JiraKit

/// 댓글은 기본이 오래된 순이다. 명시하지 않으면 20건을 받아도 가장 오래된
/// 20건이 오고, 지금 무슨 일이 벌어지는지는 알 수 없다.
@Test func commentsAreRequestedNewestFirst() async throws {
    let stub = StubHTTPClient(status: 200, body: #"{"comments":[]}"#)
    let client = JiraClient(auth: fixtureAuth(), http: stub)

    _ = try await client.comments(issueKey: "DEMO-1", limit: 20)

    let url = try #require(stub.sentRequests.last?.url?.absoluteString)
    #expect(url.contains("orderBy=-created"))
    #expect(url.contains("maxResults=20"))
}

@Test func updatingSummarySendsPutWithFieldsBody() async throws {
    let stub = StubHTTPClient(status: 204, body: "")
    let client = JiraClient(auth: fixtureAuth(), http: stub)

    try await client.updateSummary(issueKey: "DEMO-1", summary: "새 제목")

    let request = try #require(stub.sentRequests.last)
    #expect(request.httpMethod == "PUT")
    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let fields = try #require(json["fields"] as? [String: Any])
    #expect(fields["summary"] as? String == "새 제목")
}

@Test func addingCommentSendsPostWithADFBody() async throws {
    let stub = StubHTTPClient(status: 201, body: "{}")
    let client = JiraClient(auth: fixtureAuth(), http: stub)
    let document = ADFDocument(content: [.init(content: [.init(type: "text", text: "댓글")])])

    try await client.addComment(issueKey: "DEMO-1", body: document)

    let request = try #require(stub.sentRequests.last)
    #expect(request.httpMethod == "POST")
    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let adf = try #require(json["body"] as? [String: Any])
    #expect(adf["type"] as? String == "doc")
}
