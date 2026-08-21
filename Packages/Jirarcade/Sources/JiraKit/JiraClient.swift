import Foundation

public struct JiraClient: Sendable {
    private let auth: any AuthProvider
    private let http: any HTTPClient

    public init(auth: any AuthProvider, http: any HTTPClient) {
        self.auth = auth
        self.http = http
    }

    /// 사이트의 cloudId를 조회한다. `auth.baseURL`을 쓰지 않고 사이트 직접 경로의
    /// `/_edge/tenant_info`를 부른다 — 그 엔드포인트는 인증이 필요 없고, cloudId를 알아야
    /// 스코프 토큰용 베이스 URL(`api.atlassian.com/ex/jira/{cloudId}`)을 만들 수 있다.
    public func cloudId(forSite site: String) async throws -> String {
        try await resolveCloudId(site: site, http: http)
    }

    /// changelog를 함께 받는 검색. 백필의 주 경로다.
    ///
    /// `created`와 `duedate`를 fields에 넣는 이유: 백필 이벤트도 `priorUpdatedAt`과
    /// `dueDateAtObservation`을 채워야 하는데(스펙 §4.3), 첫 history 이전의 기준선은
    /// 티켓 생성 시각이고 마감일은 변경 이력이 없을 때 현재 값을 써야 한다.
    ///
    /// `expand`가 배열이 아니라 콤마 구분 **문자열**인 이유: `POST /search/jql`의 request
    /// body(`SearchAndReconcileRequestBean`)에서만 `expand`의 타입이 `string`이다. 구버전
    /// `POST /search`는 `array<string>`이라 헷갈리기 쉽지만, 여기서 배열로 보내면 400이거나
    /// 무시된 채 200이 와서 응답에 `changelog` 키가 없다 — 어느 쪽이든 백필이 0건이 된다.
    /// (`fields`는 이 엔드포인트에서도 배열이 맞다.)
    public func searchIssuesWithChangelog(
        jql: String, maxResults: Int, pageToken: String?
    ) async throws -> (issues: [JiraIssueWithChangelog], nextPageToken: String?) {
        var payload: [String: Any] = [
            "jql": jql,
            "maxResults": maxResults,
            "fields": ["created", "duedate"],
            "expand": "changelog",
        ]
        if let pageToken { payload["nextPageToken"] = pageToken }

        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await perform(method: "POST", path: "/search/jql",
                                     body: body, resource: "search")
        do {
            return try JiraChangelogResponse.decodeSearch(data)
        } catch {
            // 원본 에러를 문맥에 담는다. `decodeSearch`는 어느 티켓의 어느 필드가 깨졌는지를
            // 담아 던지므로(예: "issue MPT-1: created=..."), 여기서 버리면 수천 건을 도는
            // 백필에서 실패한 티켓을 특정할 방법이 사라진다.
            throw JiraError.decoding(context: "searchIssuesWithChangelog: \(error)")
        }
    }

    /// 티켓 하나의 changelog. 검색 응답이 잘렸을 때(`isTruncated`) 보충용이다.
    public func issueChangelog(
        issueKey: String, startAt: Int
    ) async throws -> JiraChangelogPage {
        let data = try await perform(
            method: "GET",
            path: "/issue/\(issueKey)/changelog",
            body: nil, resource: issueKey,
            query: [
                URLQueryItem(name: "startAt", value: String(startAt)),
                URLQueryItem(name: "maxResults", value: "100"),
            ]
        )
        do {
            return try JiraChangelogResponse.decodeIssueChangelog(data)
        } catch {
            throw JiraError.decoding(context: "issueChangelog(\(issueKey)): \(error)")
        }
    }

    /// JQL에 걸리는 티켓 수의 **근사값**. 백필 진행률 표시에만 쓴다.
    ///
    /// 새 검색 API(`/search/jql`)는 응답에 total을 주지 않으므로 따로 물어야 한다.
    /// "approximate"인 이유는 서버가 인덱스 통계로 답하기 때문이다 — 진행률이 100%를
    /// 넘거나 못 미칠 수 있으므로 표시할 때 클램프한다.
    public func approximateIssueCount(jql: String) async throws -> Int {
        let body = try JSONSerialization.data(withJSONObject: ["jql": jql])
        let data = try await perform(method: "POST", path: "/search/approximate-count",
                                     body: body, resource: "approximate-count")
        struct Envelope: Decodable { let count: Int }
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).count
        } catch {
            throw JiraError.decoding(context: "approximateIssueCount: \(error)")
        }
    }

    /// 사이트의 모든 상태와 그 statusCategory. 백필 시작 시 한 번 받아 캐시한다.
    public func statusCatalog() async throws -> [JiraStatusCatalogEntry] {
        let data = try await perform(method: "GET", path: "/status",
                                     body: nil, resource: "status")
        do {
            return try JiraStatusCatalogEntry.decodeList(data)
        } catch {
            throw JiraError.decoding(context: "statusCatalog: \(error)")
        }
    }

    public func myself() async throws -> JiraUser {
        let data = try await perform(method: "GET", path: "/myself", body: nil, resource: "myself")
        return try decode(JiraUser.self, from: data)
    }

    public func searchIssues(
        jql: String, fields: [String], maxResults: Int, pageToken: String?
    ) async throws -> IssuePage {
        var payload: [String: Any] = ["jql": jql, "fields": fields, "maxResults": maxResults]
        if let pageToken { payload["nextPageToken"] = pageToken }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await perform(method: "POST", path: "/search/jql", body: body, resource: "search")
        do {
            return try JiraSearchResponse.decode(data)
        } catch {
            throw JiraError.decoding(context: "search: \(error)")
        }
    }

    public func transitions(issueKey: String) async throws -> [JiraTransition] {
        let data = try await perform(method: "GET", path: "/issue/\(issueKey)/transitions",
                                     body: nil, resource: issueKey)
        do {
            return try JiraTransition.decodeList(data)
        } catch {
            throw JiraError.decoding(context: "transitions: \(error)")
        }
    }

    public func performTransition(issueKey: String, transitionId: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["transition": ["id": transitionId]])
        _ = try await perform(method: "POST", path: "/issue/\(issueKey)/transitions",
                              body: body, resource: issueKey)
    }

    // MARK: - 요청 실행

    private func perform(
        method: String, path: String, body: Data?, resource: String,
        query: [URLQueryItem] = []
    ) async throws -> Data {
        try await perform(method: method, path: path, body: body,
                          resource: resource, query: query, allowingRetry: true)
    }

    /// 스펙 §8.3: 401을 만나면 `auth.recoverFromUnauthorized()`로 갱신을 시도하고,
    /// 성공하면 요청을 한 번만 재시도한다. `allowingRetry: false`로 들어온 재시도 호출은
    /// 다시 재시도를 걸 수 없으므로, provider가 항상 true를 돌려줘도 무한 재시도로 이어지지 않는다.
    ///
    /// 재시도 요청은 이 함수 맨 위에서 `URLRequest`를 새로 만들어 처음부터 다시 빌드한다 —
    /// `authorize(_:)`가 새 자격증명을 찍어야 하고, OAuth는 Basic auth와 다른 `baseURL`을 쓰므로
    /// 예전 `URLRequest`를 재사용하면 안 된다.
    private func perform(
        method: String, path: String, body: Data?, resource: String,
        query: [URLQueryItem] = [], allowingRetry: Bool
    ) async throws -> Data {
        // 쿼리는 URLComponents로 붙인다. path에 "?..."를 이어 붙이면
        // appendingPathComponent가 `?`를 %3F로 이스케이프해 경로의 일부가 된다.
        // 빈 배열일 때 대입하지 않는 이유는 URL 끝에 `?`만 남는 것을 피하기 위해서다.
        var components = URLComponents(
            url: auth.baseURL.appendingPathComponent(path.dropFirstSlash),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw JiraError.invalidSite }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        try await auth.authorize(&request)

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.send(request)
        } catch let error as URLError {
            throw error.code == .notConnectedToInternet || error.code == .networkConnectionLost
                ? JiraError.offline
                : JiraError.server(status: -1)
        }

        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401, allowingRetry, try await auth.recoverFromUnauthorized() {
                return try await perform(method: method, path: path, body: body,
                                         resource: resource, query: query,
                                         allowingRetry: false)
            }
            throw Self.mapError(status: response.statusCode, data: data,
                                response: response, resource: resource)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw JiraError.decoding(context: "\(type): \(error)")
        }
    }

    static func mapError(
        status: Int, data: Data, response: HTTPURLResponse, resource: String
    ) -> JiraError {
        switch status {
        case 400:  return .transitionRejected(reason: firstErrorMessage(in: data) ?? "요청이 거부되었습니다")
        case 401:  return .unauthorized
        case 403:  return .forbidden(resource: resource)
        case 404:  return .notFound(key: resource)
        case 429:
            let header = response.value(forHTTPHeaderField: "Retry-After")
            return .rateLimited(retryAfter: TimeInterval(header ?? "") ?? 60)
        default:   return .server(status: status)
        }
    }

    private static func firstErrorMessage(in data: Data) -> String? {
        struct Envelope: Decodable { let errorMessages: [String]? }
        return try? JSONDecoder().decode(Envelope.self, from: data).errorMessages?.first
    }
}

private extension String {
    /// URL.appendingPathComponent가 선행 슬래시를 이중으로 만들지 않게 다듬는다.
    var dropFirstSlash: String { hasPrefix("/") ? String(dropFirst()) : self }
}
