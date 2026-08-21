import Testing
import Foundation
@testable import JiraKit

private let auth = fixtureAuth(site: "example.atlassian.net",
                               email: "user@example.com",
                               token: "secret-token")

@Test func baseURLUsesTheSiteHost() {
    #expect(auth.baseURL.absoluteString == "https://example.atlassian.net/rest/api/3")
}

@Test func siteAcceptsAFullURLAndNormalizesIt() throws {
    let fromURL = try APITokenAuth(site: "https://example.atlassian.net/",
                                   email: "user@example.com", token: "t")
    #expect(fromURL.baseURL.absoluteString == "https://example.atlassian.net/rest/api/3")
}

@Test func siteWithAPortIsAccepted() throws {
    let ported = try APITokenAuth(site: "jira.internal:8443", email: "u@e.com", token: "t")
    #expect(ported.baseURL.absoluteString == "https://jira.internal:8443/rest/api/3")
}

/// 로그인 화면은 자유 입력을 받는다. 붙여넣기 사고가 크래시가 되어서는 안 된다.
@Test(arguments: ["", "   ", "https://", "my site.example.com", "a|b.example.com"])
func invalidSiteThrowsInsteadOfCrashing(site: String) {
    #expect(throws: JiraError.invalidSite) {
        _ = try APITokenAuth(site: site, email: "user@example.com", token: "secret-token")
    }
}

/// 사이트가 잘못됐다는 에러에 자격증명이 실려서는 안 된다.
@Test func invalidSiteErrorNeverLeaksCredentials() {
    do {
        _ = try APITokenAuth(site: "my site", email: "user@example.com", token: "secret-token")
        Issue.record("잘못된 사이트인데 던지지 않았다")
    } catch {
        let text = String(describing: error)
        #expect(!text.contains("secret-token"))
        #expect(!text.contains("user@example.com"))
    }
}

@Test func authorizeSetsBasicHeader() async throws {
    var request = URLRequest(url: URL(string: "https://example.com")!)
    try await auth.authorize(&request)

    let expected = Data("user@example.com:secret-token".utf8).base64EncodedString()
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic \(expected)")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
}

@Test func apiTokenCannotRecoverFromUnauthorized() async throws {
    let recovered = try await auth.recoverFromUnauthorized()
    #expect(recovered == false, "토큰은 갱신할 수 없으므로 재로그인이 필요하다")
}

/// 전역 제약은 토큰과 이메일을 **둘 다** 금지한다.
/// 둘 다 검사해야 나중에 누가 디버깅 편의로 `description`에 이메일을 넣을 때 걸린다.
@Test func descriptionNeverLeaksCredentials() {
    let text = String(describing: auth)
    #expect(!text.contains("secret-token"))
    #expect(!text.contains("user@example.com"))
}

// MARK: - 스코프 있는 API 토큰

/// Atlassian의 **스코프 있는 API 토큰**은 Basic auth를 쓰지만 사이트 직접 경로
/// (`{site}.atlassian.net/rest/api/3`)를 받아주지 않는다. `api.atlassian.com/ex/jira/{cloudId}`
/// 로 보내야 하고, 클래식 경로로 보내면 인증 단계 **이전에** 엣지에서 거부돼
/// HTML 차단 페이지와 401이 돌아온다 — 토큰이 정상인데도.
@Test func scopedTokenAuthUsesTheCloudIdBaseURL() {
    let auth = ScopedAPITokenAuth(
        cloudId: "11111111-2222-3333-4444-555555555555",
        email: "u@e.com",
        token: "t"
    )
    #expect(auth.baseURL.absoluteString
            == "https://api.atlassian.com/ex/jira/11111111-2222-3333-4444-555555555555/rest/api/3")
}

@Test func scopedTokenAuthSendsTheSameBasicHeader() async throws {
    let auth = ScopedAPITokenAuth(cloudId: "cid", email: "user@example.com", token: "secret-token")
    var request = URLRequest(url: URL(string: "https://example.com")!)
    try await auth.authorize(&request)

    let expected = Data("user@example.com:secret-token".utf8).base64EncodedString()
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic \(expected)")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
}

@Test func scopedTokenAuthCannotRecoverFromUnauthorized() async throws {
    let auth = ScopedAPITokenAuth(cloudId: "cid", email: "u@e.com", token: "t")
    #expect(try await auth.recoverFromUnauthorized() == false)
}

@Test func scopedTokenDescriptionNeverLeaksTheToken() {
    let auth = ScopedAPITokenAuth(cloudId: "cid", email: "u@e.com", token: "secret-token")
    #expect(!String(describing: auth).contains("secret-token"))
}

// MARK: - cloudId 조회

/// 사이트 주소만 있으면 cloudId를 알아낼 수 있다 — `/_edge/tenant_info`는 인증 없이
/// `{"cloudId":"..."}`를 돌려준다. 사용자에게 UUID를 묻지 않아도 되는 이유다.
@Test func tenantInfoResolvesTheCloudId() async throws {
    let body = #"{"cloudId":"11111111-2222-3333-4444-555555555555"}"#
    let http = StubHTTPClient(status: 200, body: body)
    let resolved = try await resolveCloudId(site: "example.atlassian.net", http: http)

    #expect(resolved == "11111111-2222-3333-4444-555555555555")
    let request = try #require(http.sentRequests.first)
    #expect(request.url?.absoluteString == "https://example.atlassian.net/_edge/tenant_info")
}

@Test func tenantInfoAcceptsAFullURLAsSite() async throws {
    let http = StubHTTPClient(status: 200, body: #"{"cloudId":"cid"}"#)
    _ = try await resolveCloudId(site: "https://example.atlassian.net/", http: http)
    let request = try #require(http.sentRequests.first)
    #expect(request.url?.absoluteString == "https://example.atlassian.net/_edge/tenant_info")
}

@Test func tenantInfoFailureThrows() async {
    let http = StubHTTPClient(status: 404, body: "not found")
    await #expect(throws: (any Error).self) {
        _ = try await resolveCloudId(site: "example.atlassian.net", http: http)
    }
}

// MARK: - 사이트 정규화

/// 호스트명은 대소문자를 구분하지 않는다. 대문자로 적은 사이트가 소문자로 적은 사이트와
/// 다른 값으로 남으면, 이 값을 비교하는 쪽(계정 바인딩)이 같은 사이트를 다르게 본다.
@Test(arguments: [
    ("example.atlassian.net", "example.atlassian.net"),
    ("  example.atlassian.net  ", "example.atlassian.net"),
    ("https://example.atlassian.net", "example.atlassian.net"),
    ("HTTPS://Example.Atlassian.NET/", "example.atlassian.net"),
    ("http://example.atlassian.net///", "example.atlassian.net"),
    ("EXAMPLE.ATLASSIAN.NET", "example.atlassian.net"),
    ("jira.internal:8443", "jira.internal:8443"),
])
func siteNormalizationReducesEquivalentSpellings(input: String, expected: String) {
    #expect(JiraSite.normalize(input) == expected)
}

/// 유효성 판정은 URL을 만드는 쪽의 몫이다 — 정규화는 걸러내지 않는다.
@Test func siteNormalizationDoesNotJudgeValidity() {
    #expect(JiraSite.normalize("https://") == "")
    #expect(JiraSite.normalize("   ") == "")
}
