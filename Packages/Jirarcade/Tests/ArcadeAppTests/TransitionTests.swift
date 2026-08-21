import Testing
import Foundation
import ArcadeCore
import JiraKit
@testable import ArcadeApp

private let now = iso("2026-08-21T09:00:00Z")

/// 깨어날 시점을 테스트가 직접 정하는 sleep. `SyncScheduler`가 sleep을 주입받는 것과
/// 같은 패턴이다 — 실제로 5초를 기다리면 테스트가 5초씩 늘어나고, 밀리초로 줄이면
/// 취소 테스트가 타이밍에 따라 흔들린다.
///
/// 세 가지를 명시적으로 다룬다:
///
/// 1. **동시에 여러 `sleep()`이 걸릴 수 있다.** `AppModel`은 티켓마다 독립된 타이머를
///    갖지만, 주입하는 `transitionSleep` 클로저는 모델 하나에 하나뿐이다 — 그래서
///    `eachIssueGetsItsOwnUndoWindow`처럼 두 티켓을 연달아 옮기면 같은 `ManualSleep`
///    인스턴스에 `sleep()`이 두 번 겹쳐 걸린다. continuation을 변수 하나에만 담으면
///    두 번째 호출이 첫 번째를 덮어써 그 자리에서 즉시 버려지고, 아직 resume되지
///    않은 continuation이 사라지는 순간 런타임이 "leaked its continuation"을 찍는다.
///    큐(`waiters`)로 여러 건을 동시에 들고 있는다.
/// 2. **취소가 대기를 실제로 끝낸다.** `withCheckedContinuation`만 쓰면 감싸고 있는
///    `Task`가 취소돼도 checked continuation은 스스로 깨지 않는다 — cancel()은 플래그만
///    세울 뿐이라 계속 매달린 채로 남는다. `withTaskCancellationHandler`로 취소 신호를
///    받아 즉시 `CancellationError`로 되살린다.
/// 3. **`fire()`가 `sleep()`보다 먼저 도착해도 잃지 않는다.** `requestTransition(...)`
///    직후 바로 `fire()`를 부르는 테스트에서, 구현이 스폰한 `Task`가 실제로 `sleep()`까지
///    도달했다는 보장이 없다 — 스케줄링에 달렸다. 대기가 아직 없을 때 도착한 신호는
///    개수로 기억해 뒀다가, 그 뒤에 들어오는 `sleep()`들이 순서대로 소비한다.
///
/// `fire()`/취소가 대기 목록에서 어느 항목을 깨울지는 **선입선출**로 정한다. 이슈별로
/// 골라 깨울 수는 없다 — `transitionSleep` 인터페이스 자체가 어느 티켓의 타이머인지
/// 넘겨주지 않기 때문이다. 지금 다섯 테스트는 같은 시점에 최대 한 건만 취소하므로
/// 모호함이 없지만, 여러 티켓이 동시에 대기 중일 때 특정 티켓만 취소하는 시나리오가
/// 생기면(Task 7 이후) 이 큐만으로는 "어느 것을 깨울지" 구분할 수 없다 — 그때는
/// 인터페이스에 티켓 키를 실어 보내거나 티켓별로 별도 `ManualSleep`을 두는 확장이 필요하다.
actor ManualSleep {
    private var waiters: [CheckedContinuation<Void, Error>] = []
    /// 대기가 없을 때 도착한 `fire()`의 개수. 다음 `sleep()`들이 순서대로 소비한다.
    private var earlyFires = 0
    /// 대기가 없을 때 도착한 취소의 개수. `earlyFires`와 같은 이유로 큐로 쌓는다.
    private var earlyCancellations = 0
    private var pending = 0

    func sleep(_ duration: Duration) async throws {
        pending += 1

        if earlyFires > 0 {
            earlyFires -= 1
            return
        }
        if earlyCancellations > 0 {
            earlyCancellations -= 1
            throw CancellationError()
        }
        if Task.isCancelled { throw CancellationError() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                // 이 클로저는 `sleep()`을 부른 태스크가 매달리기 직전, 액터 위에서
                // 동기적으로 실행된다 — 취소를 전달하는 별도 태스크와 경합하더라도
                // 액터가 둘을 직렬화하므로, 어느 쪽이 먼저 실행되든 아래 세 분기 중
                // 하나로 결론이 난다. 신호를 놓치는 순서는 없다.
                if earlyFires > 0 {
                    earlyFires -= 1
                    k.resume()
                } else if earlyCancellations > 0 {
                    earlyCancellations -= 1
                    k.resume(throwing: CancellationError())
                } else {
                    waiters.append(k)
                }
            }
        } onCancel: {
            Task { await self.deliverCancellation() }
        }
    }

    /// 대기 중인 sleep 하나를 깨운다(선입선출). 아직 아무도 기다리지 않으면 다음
    /// `sleep()` 호출이 곧바로 반환하도록 기억해 둔다.
    func fire() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            earlyFires += 1
        }
    }

    /// `withTaskCancellationHandler`의 `onCancel`에서 스폰한 태스크가 부른다.
    /// 대기 중이면 그중 하나(선입선출)를 즉시 깨워 취소를 알리고, 아직 대기 전이면
    /// 기억해 뒀다가 `sleep()`이 들어오는 순간 소비한다.
    private func deliverCancellation() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume(throwing: CancellationError())
        } else {
            earlyCancellations += 1
        }
    }

    var hasSleeper: Bool { !waiters.isEmpty }
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
