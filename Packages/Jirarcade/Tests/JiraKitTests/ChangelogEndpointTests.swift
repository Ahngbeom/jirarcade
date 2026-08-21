import Testing
import Foundation
@testable import JiraKit

private let auth = fixtureAuth()

@Test func searchWithChangelogRequestsTheExpandAndFields() async throws {
    let body = #"{"issues":[],"nextPageToken":null}"#
    let stub = StubHTTPClient(status: 200, body: body)
    let client = JiraClient(auth: auth, http: stub)

    _ = try await client.searchIssuesWithChangelog(
        jql: "assignee = currentUser()", maxResults: 100, pageToken: nil
    )

    let request = try #require(stub.sentRequests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString.hasSuffix("/search/jql") == true)

    let payload = try JSONSerialization.jsonObject(
        with: #require(request.httpBody)) as? [String: Any]
    #expect(payload?["jql"] as? String == "assignee = currentUser()")
    #expect(payload?["maxResults"] as? Int == 100)
    let expand = payload?["expand"] as? [String]
    #expect(expand?.contains("changelog") == true)
    // created와 duedate가 없으면 priorUpdatedAt/dueDateAtObservation을 복원할 수 없다.
    let fields = payload?["fields"] as? [String]
    #expect(fields?.contains("created") == true)
    #expect(fields?.contains("duedate") == true)
}

@Test func pageTokenIsForwarded() async throws {
    let stub = StubHTTPClient(status: 200, body: #"{"issues":[]}"#)
    let client = JiraClient(auth: auth, http: stub)
    _ = try await client.searchIssuesWithChangelog(jql: "q", maxResults: 100, pageToken: "tok-9")

    let payload = try JSONSerialization.jsonObject(
        with: #require(stub.sentRequests.first?.httpBody)) as? [String: Any]
    #expect(payload?["nextPageToken"] as? String == "tok-9")
}

@Test func issueChangelogUsesStartAt() async throws {
    let body = #"{"startAt":10,"maxResults":100,"total":12,"values":[]}"#
    let stub = StubHTTPClient(status: 200, body: body)
    let client = JiraClient(auth: auth, http: stub)

    let page = try await client.issueChangelog(issueKey: "MPT-1", startAt: 10)

    // URLComponents로 파싱해 경로와 쿼리를 분리해서 본다. absoluteString.contains로
    // 보면 안 된다 — `?`가 `%3F`로 이스케이프돼 쿼리가 경로에 처박힌 URL도
    // contains("startAt=10")을 통과한다.
    let sent = try #require(stub.sentRequests.first?.url)
    let components = try #require(URLComponents(url: sent, resolvingAgainstBaseURL: false))
    #expect(components.path.hasSuffix("/issue/MPT-1/changelog"))
    #expect(components.queryItems?.first { $0.name == "startAt" }?.value == "10")
    #expect(components.queryItems?.first { $0.name == "maxResults" }?.value == "100")
    #expect(page.startAt == 10)
}

@Test func statusCatalogDecodesCategories() async throws {
    let body = """
    [
      { "id": "10009", "name": "To Do", "statusCategory": { "key": "new" } },
      { "id": "10016", "name": "In Progress", "statusCategory": { "key": "indeterminate" } },
      { "id": "10011", "name": "Done", "statusCategory": { "key": "done" } }
    ]
    """
    let stub = StubHTTPClient(status: 200, body: body)
    let client = JiraClient(auth: auth, http: stub)

    let catalog = try await client.statusCatalog()

    // #expect는 실패해도 멈추지 않는다. count가 어긋난 상태에서 catalog[0]을 쓰면
    // 테스트 실패가 아니라 인덱스 범위 초과로 프로세스가 죽는다 — try #require로 꺼낸다.
    #expect(catalog.count == 3)
    let first = try #require(catalog.first)
    #expect(first.id == "10009")
    #expect(first.name == "To Do")
    #expect(first.categoryKey == "new")
    #expect(try #require(catalog.dropFirst().first).categoryKey == "indeterminate")

    // `#require`를 `#require` 인자 안에 중첩하면 매크로가 재귀 확장돼 컴파일되지 않는다.
    let sent = try #require(stub.sentRequests.first?.url)
    let path = try #require(URLComponents(url: sent, resolvingAgainstBaseURL: false)).path
    #expect(path.hasSuffix("/status"))
}

@Test func changelogSearchMapsUnauthorized() async {
    let client = JiraClient(auth: auth, http: StubHTTPClient(status: 401))
    await #expect(throws: JiraError.unauthorized) {
        _ = try await client.searchIssuesWithChangelog(jql: "q", maxResults: 100, pageToken: nil)
    }
}
