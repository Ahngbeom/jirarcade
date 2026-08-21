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
