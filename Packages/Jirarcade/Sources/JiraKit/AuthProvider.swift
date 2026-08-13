import Foundation

/// 인증 헤더와 베이스 URL을 함께 만든다.
/// Basic auth는 https://{site}/rest/api/3 을, OAuth 3LO는
/// https://api.atlassian.com/ex/jira/{cloudId}/rest/api/3 을 쓰므로 둘 다 이 프로토콜 뒤에 숨긴다.
public protocol AuthProvider: Sendable {
    var baseURL: URL { get }
    func authorize(_ request: inout URLRequest) async throws
    /// 401을 만났을 때 자격증명을 갱신할 수 있으면 true. 갱신 후 호출부가 요청을 재시도한다.
    func recoverFromUnauthorized() async throws -> Bool
}
