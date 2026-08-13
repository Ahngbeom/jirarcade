import Testing
import Foundation
@testable import JiraKit

private let auth = fixtureAuth()

@Test func searchSendsJQLAndAuthorization() async throws {
    let stub = StubHTTPClient(status: 200, body: #"{"issues":[]}"#)
    let client = JiraClient(auth: auth, http: stub)
    _ = try await client.searchIssues(jql: "assignee = currentUser()", fields: ["summary"],
                                      maxResults: 50, pageToken: nil)

    let request = try #require(stub.sentRequests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString.hasSuffix("/search/jql") == true)
    #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)

    let body = try #require(request.httpBody)
    let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    #expect(payload?["jql"] as? String == "assignee = currentUser()")
}

@Test func unauthorizedMapsToJiraError() async {
    let client = JiraClient(auth: auth, http: StubHTTPClient(status: 401))
    await #expect(throws: JiraError.unauthorized) {
        _ = try await client.myself()
    }
}

@Test func rateLimitCarriesRetryAfter() async {
    let stub = StubHTTPClient(status: 429, headers: ["Retry-After": "42"])
    let client = JiraClient(auth: auth, http: stub)
    await #expect(throws: JiraError.rateLimited(retryAfter: 42)) {
        _ = try await client.myself()
    }
}

@Test func serverErrorMapsToServerCase() async {
    let client = JiraClient(auth: auth, http: StubHTTPClient(status: 503))
    await #expect(throws: JiraError.server(status: 503)) {
        _ = try await client.myself()
    }
}

@Test func transitionRejectionSurfacesJiraMessage() async {
    let body = #"{"errorMessages":["전이가 허용되지 않습니다"],"errors":{}}"#
    let stub = StubHTTPClient(status: 400, body: body)
    let client = JiraClient(auth: auth, http: stub)
    await #expect(throws: JiraError.transitionRejected(reason: "전이가 허용되지 않습니다")) {
        try await client.performTransition(issueKey: "DEMO-1", transitionId: "21")
    }
}

@Test func offlineURLErrorIsTranslated() async {
    struct OfflineClient: HTTPClient {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw URLError(.notConnectedToInternet)
        }
    }
    let client = JiraClient(auth: auth, http: OfflineClient())
    await #expect(throws: JiraError.offline) {
        _ = try await client.myself()
    }
}

@Test func successfulTransitionSendsTheTransitionId() async throws {
    let stub = StubHTTPClient(status: 204, body: "")
    let client = JiraClient(auth: auth, http: stub)
    try await client.performTransition(issueKey: "DEMO-1", transitionId: "21")

    let request = try #require(stub.sentRequests.first)
    #expect(request.url?.absoluteString.hasSuffix("/issue/DEMO-1/transitions") == true)
    let payload = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
    let transition = payload?["transition"] as? [String: Any]
    #expect(transition?["id"] as? String == "21")
}
