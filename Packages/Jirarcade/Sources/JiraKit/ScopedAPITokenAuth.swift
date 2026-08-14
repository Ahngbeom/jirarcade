import Foundation

/// **스코프 있는 API 토큰**용 인증. Basic auth를 쓰는 것은 `APITokenAuth`와 같지만
/// 베이스 URL이 다르다.
///
/// Atlassian의 스코프 토큰은 사이트 직접 경로(`{site}.atlassian.net/rest/api/3`)를
/// 받아주지 않는다. 그 경로로 보내면 인증 단계에 **도달하기도 전에** 엣지에서 거부돼
/// HTML 차단 페이지("Client must be authenticated to access this resource.")와 401이
/// 돌아온다 — 토큰이 정상이고 이메일이 맞아도 마찬가지다. 이 실패는 자격증명 문제와
/// 상태 코드가 같아서, 사용자에게는 "이메일 또는 토큰이 올바르지 않습니다"로만 보인다.
///
/// 그래서 `AuthProvider`가 헤더만 추상화하지 않고 **베이스 URL까지 함께** 만든다.
/// 이 타입은 그 설계가 실제로 흡수한 첫 사례다 — `JiraClient`와 모든 호출부는 바뀌지 않는다.
public struct ScopedAPITokenAuth: AuthProvider, CustomStringConvertible {
    private let cloudId: String
    private let email: String
    private let token: String
    public let baseURL: URL

    public init(cloudId: String, email: String, token: String) {
        self.cloudId = cloudId
        self.email = email
        self.token = token
        // cloudId는 tenant_info가 준 UUID이므로 URL로 만들 수 없는 형태가 아니다.
        // 그래도 강제 언래핑을 피하려 실패 시 api.atlassian.com 루트로 떨어뜨리면
        // 첫 요청이 404로 조용히 실패해 원인을 찾기 어려워진다 — 여기서 터지는 편이 낫다.
        self.baseURL = URL(string: "https://api.atlassian.com/ex/jira/\(cloudId)/rest/api/3")!
    }

    public func authorize(_ request: inout URLRequest) async throws {
        let credentials = Data("\(email):\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    /// API 토큰은 갱신할 수 없다. 클래식 토큰과 같다.
    public func recoverFromUnauthorized() async throws -> Bool { false }

    public var description: String { "ScopedAPITokenAuth(cloudId: \(cloudId))" }
}

/// 사이트 주소로 cloudId를 알아낸다.
///
/// `/_edge/tenant_info`는 **인증 없이** `{"cloudId":"..."}`를 돌려주는 공개 엔드포인트다.
/// 덕분에 사용자에게 UUID를 묻지 않아도 스코프 토큰 경로를 만들 수 있다 — 로그인 화면은
/// 지금처럼 사이트 주소·이메일·토큰 세 개만 받으면 된다.
public func resolveCloudId(site: String, http: any HTTPClient) async throws -> String {
    var host = site.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["https://", "http://"] where host.hasPrefix(prefix) {
        host.removeFirst(prefix.count)
    }
    while host.hasSuffix("/") { host.removeLast() }

    guard !host.isEmpty, let url = URL(string: "https://\(host)/_edge/tenant_info") else {
        throw JiraError.invalidSite
    }

    let (data, response) = try await http.send(URLRequest(url: url))
    guard (200..<300).contains(response.statusCode) else {
        throw JiraError.server(status: response.statusCode)
    }

    struct TenantInfo: Decodable { let cloudId: String }
    do {
        return try JSONDecoder().decode(TenantInfo.self, from: data).cloudId
    } catch {
        throw JiraError.decoding(context: "tenant_info")
    }
}
