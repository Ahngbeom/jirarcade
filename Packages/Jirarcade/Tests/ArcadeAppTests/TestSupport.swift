import Foundation
import ArcadeCore
import JiraKit
@testable import ArcadeApp

func iso(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: string) else {
        fatalError("잘못된 ISO8601 리터럴: \(string)")
    }
    return date
}

/// 지시한 대로 응답하는 HTTP 스텁. JiraClient에 주입한다.
final class ScriptedHTTP: HTTPClient, @unchecked Sendable {
    struct Response { let status: Int; let body: Data }
    private var queue: [Response]
    private let lock = NSLock()

    init(_ responses: [Response]) { self.queue = responses }

    convenience init(status: Int, body: String = "{}") {
        self.init([Response(status: status, body: Data(body.utf8))])
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next: Response? = lock.withLock { queue.isEmpty ? nil : queue.removeFirst() }
        guard let next else { throw URLError(.badServerResponse) }
        let http = HTTPURLResponse(url: request.url!, statusCode: next.status,
                                   httpVersion: nil, headerFields: nil)!
        return (next.body, http)
    }
}

let myselfBody = #"{"accountId":"acc-me","displayName":"Tester"}"#

@MainActor
func makeModel(
    credentials: InMemoryCredentialStore = InMemoryCredentialStore(),
    workflow: InMemoryWorkflowStore = InMemoryWorkflowStore(),
    http: @escaping () -> HTTPClient = { ScriptedHTTP(status: 200, body: myselfBody) },
    now: Date = iso("2026-08-14T09:00:00Z")
) throws -> AppModel {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    return AppModel(
        store: ArcadeStore(container: try ArcadeStore.makeInMemoryContainer()),
        credentials: credentials,
        workflow: workflow,
        clientFactory: { auth in JiraClient(auth: auth, http: http()) },
        clock: { now },
        calendar: utc
    )
}
