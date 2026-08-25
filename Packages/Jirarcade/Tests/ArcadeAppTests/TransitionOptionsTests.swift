import Testing
import Foundation
@testable import ArcadeApp
@testable import ArcadeCore
import JiraKit

/// `상태 옮기기` 메뉴가 보여줄 상태를 만드는 경로.
///
/// 이 판정이 `AppModel`에 있는 이유: `ArcadeUI`에는 테스트 타깃이 없다. 뷰가 `try?`로
/// 실패를 빈 배열에 뭉개던 시절에는 아래 어느 것도 확인할 수 없었다.

/// 경로로 답을 고르는 스텁.
///
/// 큐 방식(`ScriptedHTTP`)은 `signIn`이 요청을 몇 번 보내는지에 답이 밀린다 — 그 수가
/// 바뀌면 이 파일의 테스트가 전부 조용히 엉뚱한 응답을 받는다. 경로로 고르면 그 결합이
/// 없고, 전이 조회가 **몇 번** 나갔는지도 직접 셀 수 있다.
private final class TransitionsStub: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [(status: Int, body: String)]
    private var count = 0

    /// 전이 조회에 순서대로 내줄 답. 다 쓰면 마지막 답을 반복한다.
    init(_ answers: [(status: Int, body: String)]) { self.answers = answers }

    var transitionRequests: Int { lock.withLock { count } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let answer: (status: Int, body: String)
        if path.hasSuffix("/transitions") {
            answer = lock.withLock {
                count += 1
                return answers.count > 1 ? answers.removeFirst() : (answers.first ?? (200, "{}"))
            }
        } else if path.hasSuffix("/myself") {
            answer = (200, myselfBody)
        } else {
            answer = (200, "[]")
        }
        return (
            Data(answer.body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: answer.status,
                            httpVersion: nil, headerFields: nil)!
        )
    }
}

private func transitionsBody(_ pairs: [(id: String, name: String, to: String)]) -> String {
    let items = pairs.map {
        #"{"id":"\#($0.id)","name":"\#($0.name)","to":{"name":"\#($0.to)"}}"#
    }.joined(separator: ",")
    return #"{"transitions":[\#(items)]}"#
}

private func ok(_ pairs: [(id: String, name: String, to: String)]) -> (status: Int, body: String) {
    (200, transitionsBody(pairs))
}

/// `JiraTransition`은 `Decodable` 전용이라 테스트가 값을 만들 수 없다. id로 비교한다.
private func readyIDs(_ options: TransitionOptions?) -> [String]? {
    guard case .ready(let list) = options else { return nil }
    return list.map(\.id)
}

@MainActor
private func signedIn(_ stub: TransitionsStub) async throws -> AppModel {
    let model = try makeModel(http: { stub })
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    return model
}

/// 답이 도착할 때까지 기다린다. 고정 대기는 느린 러너에서 흔들린다.
@MainActor
private func settle(_ model: AppModel, key: String) async throws {
    for _ in 0..<200 {
        let state = model.transitionOptions[key]
        if state != nil, state != .loading { return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Test func loadingTransitionOptionsPublishesTheAnswer() async throws {
    let model = try await signedIn(TransitionsStub([
        ok([("11", "검토로", "검토"), ("21", "완료로", "완료")]),
    ]))

    model.loadTransitionOptions(for: "DEMO-1")
    #expect(model.transitionOptions["DEMO-1"] == .loading)
    try await settle(model, key: "DEMO-1")

    #expect(readyIDs(model.transitionOptions["DEMO-1"]) == ["11", "21"])
}

/// 빈 답과 실패는 **다른 상태**다. 예전에는 둘 다 "옮길 수 있는 상태가 없습니다"였다.
@MainActor
@Test func anEmptyAnswerIsReadyNotFailed() async throws {
    let model = try await signedIn(TransitionsStub([ok([])]))

    model.loadTransitionOptions(for: "DEMO-1")
    try await settle(model, key: "DEMO-1")

    #expect(readyIDs(model.transitionOptions["DEMO-1"]) == [])
}

@MainActor
@Test func aFailedFetchIsNotAnEmptyList() async throws {
    let model = try await signedIn(TransitionsStub([
        (500, #"{"errorMessages":["내부 오류: db-17"]}"#),
    ]))

    model.loadTransitionOptions(for: "DEMO-1")
    try await settle(model, key: "DEMO-1")

    guard case .failed(let message) = model.transitionOptions["DEMO-1"] else {
        Issue.record("failed가 아니다: \(String(describing: model.transitionOptions["DEMO-1"]))")
        return
    }
    // Jira 응답 본문은 화면에 닿지 않는다.
    #expect(message.contains("db-17") == false)
    #expect(message.contains("errorMessages") == false)
    #expect(message.isEmpty == false)
}

/// 후보를 캐싱하지 않는다(v0.1 스펙 §8.5). 두 번 열면 두 번 묻고, 뒤의 답이 이긴다 —
/// 관리자가 워크플로를 바꾸면 앞의 답은 즉시 틀린 값이기 때문이다.
///
/// 이슈 #5가 화면으로 확정하지 못한 질문이다. `.onAppear`가 다시 발화하는지는 여전히
/// 눈으로 봐야 하지만, **발화했을 때 실제로 다시 묻는지**는 여기서 확정된다.
@MainActor
@Test func everyLoadAsksJiraAgain() async throws {
    let stub = TransitionsStub([
        ok([("11", "검토로", "검토")]),
        ok([("31", "보류로", "보류"), ("41", "폐기로", "폐기")]),
    ])
    let model = try await signedIn(stub)

    model.loadTransitionOptions(for: "DEMO-1")
    try await settle(model, key: "DEMO-1")
    #expect(readyIDs(model.transitionOptions["DEMO-1"]) == ["11"])
    #expect(stub.transitionRequests == 1)

    model.loadTransitionOptions(for: "DEMO-1")
    // 두 번째 요청이 나가는 동안에는 앞의 목록이 화면에서 치워져 있어야 한다 —
    // 낡은 전이 ID가 눌리는 창을 만들지 않는다.
    #expect(model.transitionOptions["DEMO-1"] == .loading)
    try await settle(model, key: "DEMO-1")

    #expect(readyIDs(model.transitionOptions["DEMO-1"]) == ["31", "41"])
    #expect(stub.transitionRequests == 2)
}

/// 만료는 배너와 메뉴가 같은 사실을 말한다. 메뉴를 비워두면 "불러오는 중"으로 영원히
/// 남아 그것대로 또 하나의 거짓말이 된다.
@MainActor
@Test func anExpiredSessionSaysSoInTheMenuToo() async throws {
    let model = try await signedIn(TransitionsStub([(401, "{}")]))

    model.loadTransitionOptions(for: "DEMO-1")
    try await settle(model, key: "DEMO-1")

    #expect(model.phase == .expired)
    guard case .failed = model.transitionOptions["DEMO-1"] else {
        Issue.record("failed가 아니다: \(String(describing: model.transitionOptions["DEMO-1"]))")
        return
    }
}

/// 전이 후보는 이 계정의 워크플로에서 나온 값이다. 남겨두면 다음 로그인 직후 남의 조직
/// 상태명이 메뉴에 뜨고, 그걸 누르면 존재하지 않는 전이 ID가 나간다.
@MainActor
@Test func signOutClearsTheTransitionOptions() async throws {
    let model = try await signedIn(TransitionsStub([ok([("11", "검토로", "검토")])]))
    model.loadTransitionOptions(for: "DEMO-1")
    try await settle(model, key: "DEMO-1")
    #expect(model.transitionOptions.isEmpty == false)

    await model.signOut()

    #expect(model.transitionOptions.isEmpty)
}

/// 요청이 날아가는 동안 로그아웃하면, 뒤늦게 도착한 답이 상태를 되살리면 안 된다.
///
/// `GatedHTTP`는 취소를 전파하지 않는다 — 그래서 이 시험이 지키는 것은 "취소가 빨리
/// 전달된다"가 아니라 **"취소가 전혀 닿지 않아 요청이 끝까지 갔더라도 세대 검사가 막는다"**
/// 이다. 같은 유형의 사고가 이 앱에서 실제로 출하된 적이 있다.
@MainActor
@Test func aLateAnswerFromTheOldAccountIsDiscarded() async throws {
    let gate = GatedHTTP(leading: [
        .init(status: 200, body: Data(myselfBody.utf8)),   // /myself
        .init(status: 200, body: Data("[]".utf8)),         // signIn의 field
    ])
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["진행 중": .active])),
        http: { gate }
    )
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "tok")

    model.loadTransitionOptions(for: "DEMO-1")
    await gate.waitUntilEntered()

    await model.signOut()
    #expect(model.transitionOptions.isEmpty)

    // 로그아웃한 뒤에야 답이 도착한다.
    await gate.release(status: 200,
                       body: Data(transitionsBody([("11", "검토로", "검토")]).utf8))
    try await Task.sleep(for: .milliseconds(80))

    #expect(model.transitionOptions.isEmpty)
}
