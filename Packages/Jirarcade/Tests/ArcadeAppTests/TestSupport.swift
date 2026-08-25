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

/// HTTP 스텁이지만 지정한 한 번의 호출에서 `send(_:)` 안에 실제로 멈춰 있는다.
///
/// `ScriptedHTTP`는 큐에서 즉시 응답을 돌려주므로 "요청이 아직 날아가는 중"인 순간을
/// 만들 수 없다 — 로그아웃이 진행 중인 저장과 실제로 경합하는지 보려면 `send(_:)`가
/// 진짜로 매달려 있어야 한다. `ManualSleep`(`TransitionTests.swift`)의
/// continuation-큐 패턴을 HTTP 계층에 그대로 옮긴 것이다.
///
/// `leading`에 넣은 응답들은 즉시 돌려준다 — 로그인이 쓰는 `/myself`·`/field` 같은,
/// 시험하려는 경합과 무관한 선행 호출들이다. `leading`을 다 쓰고 나면 다음
/// `send(_:)` 호출에서 멈춰서, 테스트가 `waitUntilEntered()`로 그 사실을 확인한
/// 뒤에만 `release(status:body:)`로 재개한다.
///
/// **`Task.cancel()`에 반응하지 않는다.** `ManualSleep`은 취소를 즉시 전파하지만
/// 이 스텁은 일부러 그러지 않는다 — 이 도구가 지키려는 불변은 "취소가 빨리
/// 전달되면 안전하다"가 아니라 "취소 전달이 전혀 안 되어 요청이 끝까지 갔더라도
/// 세대 검사가 결과를 막는다"이다. 최악의 경우(취소가 네트워크 계층에 전혀 닿지
/// 않는 경우)를 시험해야 그 보장이 실제로 증명된다.
///
/// 정확히 한 번만 멈춘다: `leading`을 다 쓴 뒤 두 번째 호출이 들어오면(예: 응답
/// 처리 후 잘못 트리거된 동기화) 매달리는 대신 즉시 에러를 던진다 — 이 스텁은
/// "정확히 한 지점에서 멈추는" 시나리오를 시험하는 도구이지 범용 스크립트가 아니고,
/// 매달아 두면 구현이 실제로 퇴행했을 때 시험이 통과도 실패도 아니고 그냥 멈춰 버린다.
actor GatedHTTP: HTTPClient {
    struct Response { let status: Int; let body: Data }

    private var leading: [Response]
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasEntered = false
    private var gateConsumed = false
    private var releaseContinuation: CheckedContinuation<Response, Never>?
    private var pendingRelease: Response?
    /// 실제로 나간 요청 수. 시험이 끝난 뒤 "여분의 호출이 없었다"(=동기화가 잘못
    /// 트리거되지 않았다)를 직접 셀 수 있게 한다.
    private(set) var requestCount = 0

    init(leading: [Response]) { self.leading = leading }

    /// 게이트를 한 번 지난 뒤에도 즉시 응답할 선행 호출을 더 채워 넣는다. 로그아웃
    /// 뒤 **다른 계정으로 재로그인**하는 경합을 시험할 때 쓴다 — 그 로그인이 쓰는
    /// `/myself`·`/field` 호출은 이미 멈춰 있는 첫 게이트와 무관하게 즉시 끝나야 한다.
    func enqueueLeading(_ responses: [Response]) {
        leading.append(contentsOf: responses)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if !leading.isEmpty {
            let next = leading.removeFirst()
            return (next.body, try Self.response(for: request, status: next.status))
        }
        guard !gateConsumed else { throw URLError(.badServerResponse) }
        gateConsumed = true
        hasEntered = true
        let waiters = entryWaiters
        entryWaiters = []
        waiters.forEach { $0.resume() }

        let response: Response = await withCheckedContinuation { k in
            if let pendingRelease {
                self.pendingRelease = nil
                k.resume(returning: pendingRelease)
            } else {
                releaseContinuation = k
            }
        }
        return (response.body, try Self.response(for: request, status: response.status))
    }

    /// `leading`을 다 쓴 호출이 실제로 `send(_:)` 안에서 멈춰 있을 때까지 기다린다.
    /// 이미 멈춰 있으면 곧바로 반환한다 — `fire()`가 `sleep()`보다 먼저 도착할 수
    /// 있는 `ManualSleep`과 달리, 여기서는 호출자가 항상 멈춘 *뒤에* 기다리므로
    /// early-signal을 셀 필요는 없지만 대칭을 위해 같은 대기열 모양을 쓴다.
    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            entryWaiters.append(k)
        }
    }

    func release(status: Int, body: Data) {
        let response = Response(status: status, body: body)
        if let releaseContinuation {
            self.releaseContinuation = nil
            releaseContinuation.resume(returning: response)
        } else {
            pendingRelease = response
        }
    }

    private static func response(for request: URLRequest, status: Int) throws -> HTTPURLResponse {
        guard let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        else { throw URLError(.badURL) }
        return http
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
    sprintField: InMemorySprintFieldStore = InMemorySprintFieldStore(),
    signInHint: InMemorySignInHintStore = InMemorySignInHintStore(),
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
        sprintField: sprintField,
        signInHint: signInHint,
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
