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

/// 특정 상황을 흉내내는 데만 쓰는, 내용 없는 에러. `Equatable`이라 `#expect(throws:)`에도 쓸 수 있다.
struct StubError: Error, Equatable {}

/// - Parameters:
///   - store: 미리 상태를 심어두고 싶을 때 넘긴다. 기본값은 빈 인메모리 스토어다 —
///     테스트가 모델과 **같은** 스토어를 들고 있어야 결과를 직접 확인할 수 있다.
///   - changelogSource: 백필이 쓸 소스. 기본값(nil)이면 프로덕션 구현이 쓰인다.
@MainActor
func makeModel(
    store: ArcadeStore? = nil,
    changelogSource: (any ChangelogSource)? = nil,
    credentials: InMemoryCredentialStore = InMemoryCredentialStore(),
    workflow: InMemoryWorkflowStore = InMemoryWorkflowStore(),
    accountBinding: InMemoryAccountBindingStore = InMemoryAccountBindingStore(),
    http: @escaping () -> HTTPClient = { ScriptedHTTP(status: 200, body: myselfBody) },
    now: Date = iso("2026-08-14T09:00:00Z"),
    settings: AppSettings = .default,
    transitionSleep: (@Sendable (Duration) async throws -> Void)? = nil
) throws -> AppModel {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    return AppModel(
        store: try store ?? ArcadeStore(container: ArcadeStore.makeInMemoryContainer()),
        credentials: credentials,
        workflow: workflow,
        accountBinding: accountBinding,
        clientFactory: { auth in JiraClient(auth: auth, http: http()) },
        clock: { now },
        calendar: utc,
        settings: settings,
        changelogSourceFactory: changelogSource.map { source in { _ in source } },
        transitionSleep: transitionSleep ?? { try await Task.sleep(for: $0) }
    )
}

/// 테스트용 `ObservedIssue`. `ArcadeCoreTests`의 동명 헬퍼와 같은 모양이지만, 별도
/// 테스트 타깃이라 공유할 수 없다.
func issue(
    key: String,
    summary: String = "샘플 티켓",
    status: String,
    type: String = "개선",
    priority: String? = "Medium",
    assignee: String? = "acc-me",
    assigneeName: String? = "bahn",
    due: Date? = nil,
    updated: Date = iso("2026-08-12T00:00:00Z")
) -> ObservedIssue {
    ObservedIssue(
        key: key, summary: summary, statusName: status, issueType: type,
        priority: priority, assigneeAccountId: assignee, assigneeName: assigneeName,
        dueDate: due, jiraUpdatedAt: updated
    )
}

/// 검색 응답 본문을 만든다. 담당자를 지정할 수 있는 이유: 이벤트의 `actorAccountId`가
/// 관측 시점 담당자에서 오므로, 실행자 필터를 다루는 테스트는 이 값을 흔들어야 한다.
func issuesBody(pairs: [(key: String, status: String, assignee: String)]) -> String {
    let entries = pairs.map { pair in
        """
        {"key":"\(pair.key)","fields":{"summary":"a","status":{"name":"\(pair.status)"},\
        "issuetype":{"name":"Task"},\
        "assignee":{"accountId":"\(pair.assignee)","displayName":"Someone"},\
        "updated":"2026-08-14T09:00:00.000+0000"}}
        """
    }
    return "{\"issues\":[\(entries.joined(separator: ","))]}"
}

func issuesBody(status: String, assignee: String) -> String {
    issuesBody(pairs: [(key: "DEMO-1", status: status, assignee: assignee)])
}
