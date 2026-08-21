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
private func modelAfterSync(issuesJSON: String) async throws -> AppModel {
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: demoWorkflow),
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 200, body: Data(issuesJSON.utf8)),
            ])
        },
        now: now
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    await model.syncNow(reason: .manual)
    return model
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
