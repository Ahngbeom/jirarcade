import Foundation

public struct APITokenAuth: AuthProvider, CustomStringConvertible {
    private let host: String
    private let email: String
    private let token: String
    public let baseURL: URL

    /// site는 "example.atlassian.net" 또는 전체 URL 어느 쪽이든 받는다.
    ///
    /// URL 생성을 여기서 한 번만 하는 이유: 로그인 화면은 자유 입력 텍스트를 받으므로
    /// 붙여넣기 한 번에 공백이나 `|`가 섞일 수 있다. computed property에서 만들면
    /// 로그인 시점이 아니라 **첫 API 요청 시점에** 터져 원인 추적이 어렵다.
    ///
    /// - Throws: 사이트 문자열로 URL을 만들 수 없으면 `JiraError.invalidSite`.
    public init(site: String, email: String, token: String) throws {
        let host = Self.normalizeHost(site)
        guard !host.isEmpty, let url = URL(string: "https://\(host)/rest/api/3") else {
            throw JiraError.invalidSite
        }
        self.host = host
        self.email = email
        self.token = token
        self.baseURL = url
    }

    public func authorize(_ request: inout URLRequest) async throws {
        let credentials = Data("\(email):\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    public func recoverFromUnauthorized() async throws -> Bool { false }

    public var description: String { "APITokenAuth(host: \(host))" }

    private static func normalizeHost(_ site: String) -> String {
        var text = site.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
