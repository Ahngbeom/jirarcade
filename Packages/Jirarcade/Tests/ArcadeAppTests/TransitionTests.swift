import Testing
import Foundation
import ArcadeCore
import JiraKit
@testable import ArcadeApp

private let now = iso("2026-08-21T09:00:00Z")

/// 깨어날 시점을 테스트가 직접 정하는 sleep. `SyncScheduler`가 sleep을 주입받는 것과
/// 같은 패턴이다 — 실제로 5초를 기다리면 테스트가 5초씩 늘어나고, 밀리초로 줄이면
/// 취소 테스트가 타이밍에 따라 흔들린다.
actor ManualSleep {
    private var resume: (@Sendable () -> Void)?
    private var pending = 0

    func sleep(_ duration: Duration) async throws {
        pending += 1
        await withCheckedContinuation { continuation in
            resume = { continuation.resume() }
        }
        try Task.checkCancellation()
    }

    /// 대기 중인 sleep을 깨운다.
    func fire() {
        let block = resume
        resume = nil
        block?()
    }

    var hasSleeper: Bool { resume != nil }
}

/// `JiraTransition`은 memberwise init이 없고 `Decodable`로만 만들어진다.
/// `decodeList`가 throws라 전역 `let`에서는 부를 수 없으므로 헬퍼로 감싼다.
private func transition(
    id: String, name: String, to status: String
) throws -> JiraTransition {
    let body = """
    {"transitions":[{"id":"\(id)","name":"\(name)","to":{"name":"\(status)"}}]}
    """
    return try #require(JiraTransition.decodeList(Data(body.utf8)).first)
}

@MainActor
@Test func holdsTheRequestDuringTheUndoWindow() async throws {
    let sleeper = ManualSleep()
    let model = try makeModel(
        http: { ScriptedHTTP([.init(status: 200, body: Data(myselfBody.utf8))]) },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))

    #expect(model.pendingTransitions["DEMO-1"]?.toStatusName == "Done")
    #expect(model.pendingTransitions["DEMO-1"]?.fromStatusName == "In Progress")
}

/// 취소하면 요청이 나가지 않는다. HTTP 스텁에 응답을 하나(`/myself`)만 넣어 뒀으므로,
/// 전이 요청이 나갔다면 `badServerResponse`로 실패해 흔적이 남는다.
@MainActor
@Test func cancellingBeforeTheWindowElapsesSendsNothing() async throws {
    let sleeper = ManualSleep()
    let model = try makeModel(
        http: { ScriptedHTTP([.init(status: 200, body: Data(myselfBody.utf8))]) },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])
    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))

    model.cancelPendingTransition(issueKey: "DEMO-1")

    #expect(model.pendingTransitions["DEMO-1"] == nil)
    #expect(model.transitionFailures["DEMO-1"] == nil)
}

/// 잘못 골랐을 때 취소하고 다시 고르는 것과 결과가 같아야 한다.
@MainActor
@Test func requestingAgainForTheSameIssueReplacesTheWaitingOne() async throws {
    let sleeper = ManualSleep()
    let model = try makeModel(
        http: { ScriptedHTTP([.init(status: 200, body: Data(myselfBody.utf8))]) },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))
    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "21", name: "리뷰로", to: "In Review"))

    #expect(model.pendingTransitions.count == 1)
    #expect(model.pendingTransitions["DEMO-1"]?.transitionId == "21")
    #expect(model.pendingTransitions["DEMO-1"]?.toStatusName == "In Review")
}

/// 두 티켓을 연달아 옮겨도 각자 자기 창을 갖는다. 하나만 대기하게 하면 앞의 것이
/// 즉시 확정되어 취소 기회를 잃는다.
@MainActor
@Test func eachIssueGetsItsOwnUndoWindow() async throws {
    let sleeper = ManualSleep()
    let model = try makeModel(
        http: { ScriptedHTTP([.init(status: 200, body: Data(myselfBody.utf8))]) },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([
        issue(key: "DEMO-1", status: "In Progress"),
        issue(key: "DEMO-2", status: "In Progress"),
    ])

    model.requestTransition(issueKey: "DEMO-1", transition: try transition(id: "31", name: "완료로", to: "Done"))
    model.requestTransition(issueKey: "DEMO-2", transition: try transition(id: "31", name: "완료로", to: "Done"))

    #expect(model.pendingTransitions.count == 2)
}

/// 미러에 없는 티켓은 되돌릴 기준 상태를 알 수 없으므로 요청 자체를 받지 않는다.
@MainActor
@Test func ignoresATransitionForAnUnknownIssue() async throws {
    let model = try makeModel(now: now)
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")

    model.requestTransition(issueKey: "DEMO-404",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))

    #expect(model.pendingTransitions.isEmpty)
}
