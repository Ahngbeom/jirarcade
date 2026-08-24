import Testing
import Foundation
import ArcadeCore
import JiraKit
@testable import ArcadeApp

private let now = iso("2026-08-21T09:00:00Z")

/// `ArcadeCoreTests`의 `demoWorkflow`는 다른 테스트 타깃(`internal`)이라 여기서 보이지
/// 않는다. `BoardStateTests.swift`의 사본과 같은 이유로 이 파일에서만 쓰는 사본을 둔다.
private let demoWorkflow = WorkflowMap(statusToStage: [
    "To Do": .backlog,
    "In Progress": .active,
    "In Review": .review,
    "Verifying": .verify,
    "Done": .done,
])

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

/// `sleeper.fire()` 이후 `executeTransition`이 끝날 때까지 협조적으로 양보한다.
///
/// `fire()`는 대기 중이던 sleep의 continuation을 재개할 뿐이다 — 그 뒤로
/// `executeTransition`이 실제 HTTP 호출을 보내고(성공 시) 뒤따르는 `syncNow(...)`까지
/// 끝내려면, `[weak self]` 클로저 안에서 스폰된 태스크가 `ManualSleep` 액터에서
/// `MainActor`로 다시 홉하는 것을 포함해 여러 번의 스케줄링 홉을 거쳐야 한다. 그 홉
/// 수는 실행마다 달라진다(실측 12~15회) — 실제 시간이 걸리는 게 아니라 협력형
/// 스케줄러가 대기 중인 작업을 언제 큐에서 꺼내는지가 매번 다르기 때문이다.
/// 그래서 `await Task.yield()` 한 번으로는 불충분할 수 있다: 조건이 참이 될 때까지
/// 반복해서 양보한다. 실시간 sleep이 아니므로 진짜로 끝나지 않는 경로가 있어도
/// 테스트가 몇 초씩 늘어지지 않고, 그런 경우에는 `limit`에 도달해 조건이 여전히
/// 거짓인 채로 반환되어 뒤따르는 `#expect`가 실패로 드러낸다.
@MainActor
private func settle(limit: Int = 200, until condition: () -> Bool) async {
    var remaining = limit
    while !condition() && remaining > 0 {
        await Task.yield()
        remaining -= 1
    }
}

/// 로그인 직후 곧바로 `.ready`로 가는 워크플로 저장소.
///
/// 이 파일의 테스트는 `signIn(...)` 뒤에 HTTP 스텁을 정확히 몇 번 쓸지 큐로 미리
/// 정해 둔다(`/myself` 다음에 전이 요청, 성공 시 그 다음에 동기화). 워크플로 매핑이
/// 없으면 `routeAfterAuthentication()`이 `.mappingWorkflow`로 보내고, 그 상태는
/// 화면이 후보 목록을 얻으려고 **또 다른 HTTP 요청**(`mappingCandidates()`)을 조용히
/// 보낸다 — 큐에서 전이 요청 몫으로 넣어 둔 응답을 그 요청이 가로채 버려서, 실제
/// 전이 요청은 큐가 빈 채로 나가 `badServerResponse`를 맞는다. 매핑을 심어 두면
/// `.ready`로 곧장 가서 이 여분의 요청이 아예 생기지 않는다. 매핑 내용 자체는 이
/// 테스트들의 관심사가 아니므로 최소한(전이 전후 상태 두 개)만 채운다.
private func readySeededWorkflow() -> InMemoryWorkflowStore {
    InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["In Progress": .active, "Done": .done]))
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
}

/// `Duration.components.seconds`만 쓰면 서브초 성분(attoseconds)이 잘려 `firesAt`이
/// 부정확해진다(최종 전체 브랜치 리뷰 Finding 3의 이연 발견). 정수 초가 아닌 창으로
/// 재현한다 — 잘렸다면 결과가 1.5초가 아니라 1초가 된다.
@MainActor
@Test func firesAtUsesTheFullSubsecondDuration() async throws {
    let settings = AppSettings(
        syncInterval: .seconds(300), foregroundCooldown: .seconds(30),
        backoffSteps: [.seconds(5)], failuresBeforeSurfacing: 3,
        transitionUndoWindow: .milliseconds(1500)
    )
    let model = try makeModel(
        http: { ScriptedHTTP([.init(status: 200, body: Data(myselfBody.utf8))]) },
        now: now, settings: settings,
        transitionSleep: { _ in try await Task.sleep(for: .seconds(999)) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))

    let firesAt = try #require(model.pendingTransitions["DEMO-1"]?.firesAt)
    #expect(firesAt == now.addingTimeInterval(1.5))
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

/// 창이 지나면 요청이 나가고, 성공하면 동기화가 뒤따른다. XP를 직접 주지 않고
/// diff가 이벤트를 만들게 하는 것이 이 앱의 채점 불변식을 지키는 방법이다.
@MainActor
@Test func firingTheTransitionSyncsAfterSuccess() async throws {
    let sleeper = ManualSleep()
    let model = try makeModel(
        workflow: readySeededWorkflow(),
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),   // /myself
                .init(status: 200, body: Data("[]".utf8)),         // signIn의 field
                .init(status: 204, body: Data()),                  // POST transitions
                .init(status: 200, body: Data(issuesBody(pairs: []).utf8)), // 뒤따르는 동기화
            ])
        },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])
    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))

    await sleeper.fire()
    await settle { model.lastSync != nil }

    #expect(model.pendingTransitions["DEMO-1"] == nil)
    #expect(model.transitionFailures["DEMO-1"] == nil)
    #expect(model.lastSync != nil)
}

/// 400은 대부분 "필수 필드가 비어 있다"이다. 사유는 Jira 응답 본문에서 오고 그 안에
/// 이메일이 섞일 수 있으므로 화면에 옮기지 않는다 — 대신 Jira로 가는 길을 준다.
@MainActor
@Test func aRejectedTransitionRollsBackWithoutQuotingJira() async throws {
    let sleeper = ManualSleep()
    let leak = "someone@example.com"
    let model = try makeModel(
        workflow: readySeededWorkflow(),
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 200, body: Data("[]".utf8)),   // signIn의 field
                .init(status: 400,
                      body: Data(#"{"errorMessages":["\#(leak) 필드가 필요합니다"]}"#.utf8)),
            ])
        },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])
    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))

    await sleeper.fire()
    await settle { model.transitionFailures["DEMO-1"] != nil }

    #expect(model.pendingTransitions["DEMO-1"] == nil)
    let message = try #require(model.transitionFailures["DEMO-1"])
    #expect(!message.contains(leak), "Jira 응답 본문이 화면 문구에 섞였다: \(message)")
    #expect(!message.contains("@"))
}

@MainActor
@Test func anExpiredTokenDuringTransitionGoesToTheExpiredPhase() async throws {
    let sleeper = ManualSleep()
    let model = try makeModel(
        workflow: readySeededWorkflow(),
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 200, body: Data("[]".utf8)),   // signIn의 field
                .init(status: 401, body: Data()),
            ])
        },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])
    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))

    await sleeper.fire()
    await settle { model.phase == .expired }

    #expect(model.phase == .expired)
    #expect(model.pendingTransitions["DEMO-1"] == nil)
    // 만료 배너가 이미 같은 사실을 말한다. 카드에도 실패를 띄우면 인증 문제가 두 번 보인다.
    #expect(model.transitionFailures["DEMO-1"] == nil)
}

@MainActor
@Test func dismissingClearsTheFailure() async throws {
    let sleeper = ManualSleep()
    let model = try makeModel(
        workflow: readySeededWorkflow(),
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 200, body: Data("[]".utf8)),   // signIn의 field
                .init(status: 500, body: Data()),
            ])
        },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])
    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))
    await sleeper.fire()
    await settle { model.transitionFailures["DEMO-1"] != nil }
    #expect(model.transitionFailures["DEMO-1"] != nil)

    model.dismissTransitionFailure(issueKey: "DEMO-1")

    #expect(model.transitionFailures["DEMO-1"] == nil)
}

/// 대기 중인 전이는 카드를 새 레인으로 옮겨 그린다. 스토어는 건드리지 않으므로
/// 취소하면 그냥 원래 자리로 돌아온다 — 되돌릴 것이 없다.
@MainActor
@Test func aPendingTransitionMovesTheCardOptimistically() async throws {
    let sleeper = ManualSleep()
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: demoWorkflow),
        http: { ScriptedHTTP([.init(status: 200, body: Data(myselfBody.utf8))]) },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "21", name: "리뷰로", to: "In Review"))
    let moved = model.boardSnapshot(minimumSpacing: 0.1)

    #expect(moved.lanes[1].slots.isEmpty, "ACTIVE에 남아 있다")
    #expect(moved.lanes[2].slots.map(\.issue.key) == ["DEMO-1"], "REVIEW로 옮겨지지 않았다")

    model.cancelPendingTransition(issueKey: "DEMO-1")
    let restored = model.boardSnapshot(minimumSpacing: 0.1)

    #expect(restored.lanes[1].slots.map(\.issue.key) == ["DEMO-1"])
    #expect(restored.lanes[2].slots.isEmpty)
}
