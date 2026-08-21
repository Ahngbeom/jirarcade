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
    // `POST /search/jql`에서만 expand가 배열이 아니라 콤마 구분 문자열이다.
    // 배열로 보내면 400이거나 changelog 없이 200이 와서 백필이 0건이 된다.
    #expect(payload?["expand"] as? String == "changelog")
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

/// 카탈로그 한 항목이 어긋나도 나머지는 살아야 한다. 폴백 ②가 통째로 죽으면
/// 매핑에 없는 과거 상태가 전부 0점 처리된다.
@Test func statusCatalogSkipsUndecodableEntriesAndKeepsTheRest() async throws {
    let body = """
    [
      { "id": "10009", "name": "To Do", "statusCategory": { "key": "new" } },
      { "id": "10016", "name": "이름 없는 상태" },
      { "id": "10011", "name": "Done", "statusCategory": { "key": "done" } }
    ]
    """
    let client = JiraClient(auth: auth, http: StubHTTPClient(status: 200, body: body))

    let catalog = try await client.statusCatalog()

    #expect(catalog.map(\.id) == ["10009", "10011"])
}

/// 최상위 형태가 어긋나면 관대함이 적용되지 않고 그대로 던져야 한다 —
/// 그건 "낯선 항목"이 아니라 엔드포인트/응답이 통째로 다르다는 뜻이다.
@Test func statusCatalogThrowsWhenTheResponseIsNotAnArray() async {
    let client = JiraClient(auth: auth, http: StubHTTPClient(status: 200, body: #"{"values":[]}"#))
    await #expect(throws: (any Error).self) {
        _ = try await client.statusCatalog()
    }
}

/// 401 복구 후의 재시도가 `query`를 잃으면 `startAt` 없이 첫 페이지를 다시 받아,
/// 백필이 같은 이력을 중복 삽입하거나 페이지 루프가 끝나지 않는다.
/// 재시도 요청의 URL을 직접 파싱해 쿼리가 살아 있는지 본다.
@Test func unauthorizedRetryKeepsTheQueryString() async throws {
    let page = #"{"startAt":10,"maxResults":100,"total":12,"values":[]}"#
    let stub = StubHTTPClient([
        .init(status: 401, body: Data(), headers: [:]),
        .init(status: 200, body: Data(page.utf8), headers: [:]),
    ])
    let client = JiraClient(auth: StubAuthProvider(recovers: true), http: stub)

    _ = try await client.issueChangelog(issueKey: "MPT-1", startAt: 10)

    #expect(stub.sentRequests.count == 2)
    let retried = try #require(stub.sentRequests.dropFirst().first?.url)
    let components = try #require(URLComponents(url: retried, resolvingAgainstBaseURL: false))
    #expect(components.path.hasSuffix("/issue/MPT-1/changelog"))
    #expect(components.queryItems?.first { $0.name == "startAt" }?.value == "10")
    #expect(components.queryItems?.first { $0.name == "maxResults" }?.value == "100")
}

@Test func changelogSearchMapsUnauthorized() async {
    let client = JiraClient(auth: auth, http: StubHTTPClient(status: 401))
    await #expect(throws: JiraError.unauthorized) {
        _ = try await client.searchIssuesWithChangelog(jql: "q", maxResults: 100, pageToken: nil)
    }
}

/// 진행률 총계는 별도 엔드포인트에 물어야 한다 — `POST /search/jql`은 응답에 total을
/// 주지 않는다. 본문은 JQL 하나뿐이고, 응답의 `count`를 그대로 읽는다.
@Test func approximateCountPostsTheJqlAndReadsCount() async throws {
    let stub = StubHTTPClient(status: 200, body: #"{"count":1263}"#)
    let client = JiraClient(auth: auth, http: stub)

    let count = try await client.approximateIssueCount(jql: "assignee = currentUser()")

    #expect(count == 1263)
    let request = try #require(stub.sentRequests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString.hasSuffix("/search/approximate-count") == true)
    let payload = try JSONSerialization.jsonObject(
        with: #require(request.httpBody)) as? [String: Any]
    #expect(payload?["jql"] as? String == "assignee = currentUser()")
}

/// 응답 모양이 예상과 다르면 던진다. 조용히 0을 돌려주면 진행률이 "0/0"으로 굳어
/// 사용자는 백필이 멈춘 것으로 읽는다.
@Test func approximateCountRejectsAnUnexpectedShape() async throws {
    let stub = StubHTTPClient(status: 200, body: #"{"total":1263}"#)
    let client = JiraClient(auth: auth, http: stub)

    await #expect(throws: (any Error).self) {
        _ = try await client.approximateIssueCount(jql: "q")
    }
}
