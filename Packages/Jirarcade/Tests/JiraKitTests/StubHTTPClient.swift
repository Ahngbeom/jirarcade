import Foundation
@testable import JiraKit

/// 미리 정한 응답을 순서대로 돌려주는 테스트용 클라이언트.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Response { let status: Int; let body: Data; let headers: [String: String] }

    private var queue: [Response]
    private(set) var sentRequests: [URLRequest] = []
    private let lock = NSLock()

    init(_ responses: [Response]) { self.queue = responses }

    convenience init(status: Int, body: String = "{}", headers: [String: String] = [:]) {
        self.init([Response(status: status, body: Data(body.utf8), headers: headers)])
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next: Response? = lock.withLock {
            sentRequests.append(request)
            guard !queue.isEmpty else { return nil }
            return queue.removeFirst()
        }
        guard let next else { throw URLError(.badServerResponse) }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: next.status,
            httpVersion: nil, headerFields: next.headers
        )!
        return (next.body, http)
    }
}
