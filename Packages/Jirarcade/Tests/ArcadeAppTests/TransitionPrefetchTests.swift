import Testing
import Foundation
@testable import ArcadeApp
@testable import ArcadeCore
import JiraKit

/// 동기화가 끝나면 미러의 티켓 전이 후보를 미리 받아 두고, 메뉴를 열면 그 답이 즉시 뜬다.
///
/// 이 경로가 생긴 이유는 지연이다 — 메뉴를 열 때마다 왕복을 기다리는 것이 매일 가장
/// 자주 겪는 대기였다. 미리 받아 둔 답은 **자리만 채운다**: 메뉴는 여전히 다시 묻고
/// (`TransitionOptionsTests.everyLoadAsksJiraAgain`), 새 답이 오면 교체된다.

/// 경로로 답을 고르는 스텁. 검색에는 지정한 티켓 목록을, 전이 조회에는 키별 답을 준다.
private final class PrefetchStub: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var searchBodies: [String]
    private let transitionStatus: Int
    private var asked: [String] = []

    /// - Parameters:
    ///   - searchBodies: 동기화마다 순서대로 내줄 검색 응답. 다 쓰면 마지막 것을 반복한다.
    ///   - transitionStatus: 전이 조회에 돌려줄 상태 코드. 200이면 티켓 키를 담은 답을 준다.
    init(searchBodies: [String], transitionStatus: Int = 200) {
        self.searchBodies = searchBodies
        self.transitionStatus = transitionStatus
    }

    /// 전이 조회를 받은 티켓 키, 요청 순서대로.
    var askedKeys: [String] { lock.withLock { asked } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let answer: (status: Int, body: String)
        if path.hasSuffix("/transitions") {
            let key = path.split(separator: "/").dropLast().last.map(String.init) ?? "?"
            lock.withLock { asked.append(key) }
            answer = (transitionStatus,
                      #"{"transitions":[{"id":"t-\#(key)","name":"다음으로","to":{"name":"검토"}}]}"#)
        } else if path.hasSuffix("/search/jql") {
            answer = (200, lock.withLock {
                searchBodies.count > 1 ? searchBodies.removeFirst() : (searchBodies.first ?? "{\"issues\":[]}")
            })
        } else if path.hasSuffix("/myself") {
            answer = (200, myselfBody)
        } else {
            answer = (200, "[]")
        }
        return (Data(answer.body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: answer.status,
                                httpVersion: nil, headerFields: nil)!)
    }
}

private func readyIDs(_ options: TransitionOptions?) -> [String]? {
    guard case .ready(let list) = options else { return nil }
    return list.map(\.id)
}

@MainActor
private func readyModel(_ stub: PrefetchStub, settings: AppSettings = .default) async throws -> AppModel {
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["진행 중": .active])),
        http: { stub }, settings: settings
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    #expect(model.phase == .ready)
    return model
}

/// 사전 로드는 별도 태스크라 `syncNow()`가 돌아온 뒤에 끝난다. 고정 대기는 느린 러너에서
/// 흔들리므로 요청 수가 목표에 닿을 때까지 기다린다.
///
/// 이 대기는 "요청이 **나갔다**"까지다. 답을 받아 둔 것까지 기다리려면 `waitForWarm`을
/// 쓴다 — 둘 사이에 틈이 있고, 그 틈에서 메뉴를 열면 아직 차갑다.
private func waitForAsks(_ stub: PrefetchStub, count: Int) async throws {
    for _ in 0..<200 {
        if stub.askedKeys.count >= count { return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func waitForWarm(_ model: AppModel, count: Int) async throws {
    for _ in 0..<200 {
        if model.warmTransitionCountForTesting >= count { return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Test func aSyncPrefetchesTransitionsForEveryMirroredTicket() async throws {
    let stub = PrefetchStub(searchBodies: [issuesBody(pairs: [
        ("DEMO-1", "진행 중", "acc-me"), ("DEMO-2", "진행 중", "acc-me"), ("DEMO-3", "진행 중", "acc-me"),
    ])])
    let model = try await readyModel(stub)

    await model.syncNow()
    try await waitForAsks(stub, count: 3)

    #expect(Set(stub.askedKeys) == ["DEMO-1", "DEMO-2", "DEMO-3"])
    // 아직 메뉴를 연 적이 없다 — 미리 받아 둔 것은 메뉴 상태가 아니다.
    #expect(model.transitionOptions.isEmpty)
}

/// 메뉴를 열면 미리 받아 둔 답이 **즉시** `.ready`로 뜬다. 그리고 여전히 다시 묻는다.
@MainActor
@Test func openingTheMenuShowsTheWarmAnswerImmediatelyAndStillAsksAgain() async throws {
    let stub = PrefetchStub(searchBodies: [issuesBody(status: "진행 중", assignee: "acc-me")])
    let model = try await readyModel(stub)
    await model.syncNow()
    try await waitForWarm(model, count: 1)

    model.loadTransitionOptions(for: "DEMO-1")

    #expect(readyIDs(model.transitionOptions["DEMO-1"]) == ["t-DEMO-1"])
    try await waitForAsks(stub, count: 2)
    #expect(stub.askedKeys == ["DEMO-1", "DEMO-1"])
}

/// 상태가 바뀐 티켓의 답은 낡은 것이다 — 다음 동기화가 그 티켓만 다시 받는다.
@MainActor
@Test func aStatusChangeInvalidatesOnlyThatTicketsWarmAnswer() async throws {
    let stub = PrefetchStub(searchBodies: [
        issuesBody(pairs: [("DEMO-1", "진행 중", "acc-me"), ("DEMO-2", "진행 중", "acc-me")]),
        issuesBody(pairs: [("DEMO-1", "검토 중", "acc-me"), ("DEMO-2", "진행 중", "acc-me")]),
    ])
    let model = try await readyModel(stub)
    await model.syncNow()
    try await waitForWarm(model, count: 2)

    await model.syncNow()
    try await waitForAsks(stub, count: 3)
    try await Task.sleep(for: .milliseconds(40))

    #expect(stub.askedKeys.count == 3)
    #expect(stub.askedKeys.last == "DEMO-1")
}

/// 사전 로드는 설정으로 끌 수 있다. 꺼져 있으면 동기화 뒤에 전이 조회가 하나도 나가지 않는다.
@MainActor
@Test func prefetchCanBeSwitchedOff() async throws {
    let stub = PrefetchStub(searchBodies: [issuesBody(status: "진행 중", assignee: "acc-me")])
    let model = try await readyModel(stub, settings: .quiet)

    await model.syncNow()
    try await Task.sleep(for: .milliseconds(60))

    #expect(stub.askedKeys.isEmpty)
    // 받아 둔 것이 없으므로 메뉴는 차갑게 시작한다.
    model.loadTransitionOptions(for: "DEMO-1")
    #expect(model.transitionOptions["DEMO-1"] == .loading)
}

/// 사전 로드 중 401은 만료 배너와 같은 사실이다. 남은 티켓을 계속 물어봐야 같은 답이다.
@MainActor
@Test func anUnauthorizedPrefetchExpiresTheSessionAndStops() async throws {
    var settings = AppSettings.default
    settings.transitionPrefetchConcurrency = 1
    let stub = PrefetchStub(searchBodies: [issuesBody(pairs: [
        ("DEMO-1", "진행 중", "acc-me"), ("DEMO-2", "진행 중", "acc-me"), ("DEMO-3", "진행 중", "acc-me"),
    ])], transitionStatus: 401)
    let model = try await readyModel(stub, settings: settings)

    await model.syncNow()
    try await waitForAsks(stub, count: 1)
    try await Task.sleep(for: .milliseconds(60))

    #expect(model.phase == .expired)
    #expect(stub.askedKeys.count == 1)
}

/// 미리 받아 둔 답도 이 계정의 것이다. 로그아웃하면 사라지고 다음 메뉴는 차갑게 시작한다.
@MainActor
@Test func signOutForgetsTheWarmAnswers() async throws {
    let stub = PrefetchStub(searchBodies: [issuesBody(status: "진행 중", assignee: "acc-me")])
    let model = try await readyModel(stub)
    await model.syncNow()
    try await waitForWarm(model, count: 1)

    await model.signOut()
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "진행 중")])

    model.loadTransitionOptions(for: "DEMO-1")
    #expect(model.transitionOptions["DEMO-1"] == .loading)
}

/// 너무 오래된 답은 없는 셈 친다 — 동기화가 멈춰 있던 사이 워크플로가 바뀌었을 수 있다.
///
/// 시계가 고정이라 "60초 뒤"를 만들 수 없다. 대신 창을 0초로 두어 "받은 즉시 낡는"
/// 극단을 고정한다 — 경계가 `<`인지 `<=`인지까지 이 시험이 정한다.
@MainActor
@Test func aWarmAnswerOlderThanTheWarmthWindowIsIgnored() async throws {
    var settings = AppSettings.default
    settings.transitionWarmth = .zero
    let stub = PrefetchStub(searchBodies: [issuesBody(status: "진행 중", assignee: "acc-me")])
    let model = try await readyModel(stub, settings: settings)
    await model.syncNow()
    try await waitForWarm(model, count: 1)

    model.loadTransitionOptions(for: "DEMO-1")
    #expect(model.transitionOptions["DEMO-1"] == .loading)
}
