import Testing
import Foundation
import ArcadeCore
import JiraKit
@testable import ArcadeApp

private let now = iso("2026-08-21T09:00:00Z")

/// `ArcadeCoreTests`의 `demoWorkflow`는 다른 테스트 타깃(`internal`)이라 여기서 보이지
/// 않는다. 공유 픽스처를 옮기는 대신 이 파일에서만 쓰는 작은 사본을 둔다.
private let demoWorkflow = WorkflowMap(statusToStage: [
    "To Do": .backlog,
    "In Progress": .active,
    "In Review": .review,
    "Verifying": .verify,
    "Done": .done,
])

/// 동기화 한 번을 흉내낸다. `/myself` → 검색 응답 순서로 스크립트한다.
///
/// 워크플로를 미리 심는 이유: 매핑이 없으면 `routeAfterAuthentication()`이 마법사로
/// 보내고 `HygieneCalculator`가 단계를 못 갈라 위생 지표가 전부 0이 된다.
@MainActor
private func modelAfterSync(
    issuesJSON: String,
    transitionSleep: (@Sendable (Duration) async throws -> Void)? = nil
) async throws -> AppModel {
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: demoWorkflow),
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 200, body: Data("[]".utf8)),   // signIn의 field
                .init(status: 200, body: Data(issuesJSON.utf8)),
            ])
        },
        now: now,
        transitionSleep: transitionSleep
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    await model.syncNow(reason: .manual)
    return model
}

/// `JiraTransition`은 memberwise init이 없고 `Decodable`로만 만들어진다. `TransitionTests.swift`의
/// 사본과 같은 이유로 이 파일에서만 쓰는 최소 버전을 둔다.
private func transition(id: String, name: String, to status: String) throws -> JiraTransition {
    let body = """
    {"transitions":[{"id":"\(id)","name":"\(name)","to":{"name":"\(status)"}}]}
    """
    return try #require(JiraTransition.decodeList(Data(body.utf8)).first)
}

@MainActor
@Test func exposesTheMirrorSortedByKey() async throws {
    let model = try await modelAfterSync(issuesJSON: issuesBody(pairs: [
        (key: "DEMO-9", status: "In Progress", assignee: "acc-me"),
        (key: "DEMO-2", status: "To Do", assignee: "acc-me"),
    ]))

    #expect(model.issues.map(\.key) == ["DEMO-2", "DEMO-9"])
}

@MainActor
@Test func exposesTheEffectiveWorkflowMap() async throws {
    let model = try makeModel(workflow: InMemoryWorkflowStore(seeded: demoWorkflow),
                              now: now)

    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")

    #expect(model.boardWorkflow.stage(for: "In Progress") == .active)
}

@MainActor
@Test func exposesTheHygieneReport() async throws {
    let model = try await modelAfterSync(issuesJSON: issuesBody(
        status: "In Progress", assignee: "acc-me"
    ))

    #expect(model.hygiene != nil)
    #expect(model.hygiene?.wipCount == 1)
}

/// Jira 링크를 만들려면 호스트가 필요하다. 자격증명 전체가 아니라 호스트 문자열
/// 하나만 노출한다 — 이메일과 토큰은 화면에 닿을 이유가 없다.
@MainActor
@Test func exposesTheNormalizedSiteHost() async throws {
    let model = try makeModel(now: now)

    await model.signIn(site: "HTTPS://Example.Atlassian.Net/",
                           email: "t@example.com", token: "tok")

    #expect(model.siteHost == "example.atlassian.net")
}

@MainActor
@Test func clearsBoardStateOnSignOut() async throws {
    let model = try await modelAfterSync(issuesJSON: issuesBody(
        status: "In Progress", assignee: "acc-me"
    ))
    #expect(!model.issues.isEmpty)

    await model.signOut()

    #expect(model.issues.isEmpty)
    #expect(model.statusEnteredAt.isEmpty)
    #expect(model.hygiene == nil)
    #expect(model.siteHost == nil)
}

/// 로그아웃 시점에 대기 중이던 전이가 있으면, 그 타이머는 다음 계정으로 로그인한 뒤에도
/// 계속 살아 있다가 엉뚱한 사이트로 `POST /issue/{key}/transitions`를 쏠 수 있다
/// (최종 전체 브랜치 리뷰 Finding 1). `signOut()`은 `syncGeneration`처럼 이 경계를
/// 지켜야 하는데, 지금은 `pendingTransitions`·`transitionFailures`·타이머 태스크
/// 어느 것도 건드리지 않는다 — 이 테스트가 그 셋을 모두 확인한다.
///
/// `transitionSleep`을 999초로 주입해 타이머가 테스트 시간 안에는 절대 스스로 끝나지
/// 않게 한다 — signOut() 시점에 "대기 중"이라는 상태를 보장하기 위해서다.
@MainActor
@Test func clearsTransitionStateOnSignOut() async throws {
    let model = try await modelAfterSync(
        issuesJSON: issuesBody(status: "In Progress", assignee: "acc-me"),
        transitionSleep: { _ in try await Task.sleep(for: .seconds(999)) }
    )
    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))
    #expect(!model.pendingTransitions.isEmpty)
    #expect(model.transitionTaskCountForTesting == 1)

    await model.signOut()

    #expect(model.pendingTransitions.isEmpty)
    #expect(model.transitionFailures.isEmpty)
    #expect(model.transitionTaskCountForTesting == 0)
}

/// 뷰가 시계와 달력을 직접 만들지 않도록 모델이 스냅샷을 준다.
@MainActor
@Test func buildsTheBoardSnapshotWithTheInjectedClock() async throws {
    let model = try makeModel(workflow: InMemoryWorkflowStore(seeded: demoWorkflow),
                              now: now)
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([
        issue(key: "DEMO-1", status: "In Progress",
              updated: now.addingTimeInterval(-30 * 86_400)),
    ])

    let snapshot = model.boardSnapshot(minimumSpacing: 0.1)

    #expect(snapshot.lanes.map(\.stage) == [.backlog, .active, .review, .verify])
    #expect(snapshot.lanes[1].slots.first?.daysStagnant == 30)
    #expect(snapshot.axis.map(\.days) == [0, 7, 21, 45])
}

@MainActor
@Test func exposesTheWIPLimitFromTheRuleSet() throws {
    let model = try makeModel(now: now)

    #expect(model.wipLimit == RuleSet.default.wipLimit)
}
