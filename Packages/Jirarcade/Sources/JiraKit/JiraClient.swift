import Foundation

public struct JiraClient: Sendable {
    private let auth: any AuthProvider
    private let http: any HTTPClient

    public init(auth: any AuthProvider, http: any HTTPClient) {
        self.auth = auth
        self.http = http
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

    private func perform(method: String, path: String, body: Data?, resource: String) async throws -> Data {
        var request = URLRequest(url: auth.baseURL.appendingPathComponent(path.dropFirstSlash))
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
