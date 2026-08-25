import Testing
import Foundation
import ArcadeCore
@testable import ArcadeApp

/// 만료 → 갱신 경로를 한 번에 흉내내기 위한 응답 대본.
/// 같은 인스턴스를 계속 넘겨야 요청이 순서대로 소진된다 — `makeModel(http:)`의 클로저는
/// 클라이언트를 만들 때마다 불리므로, 안에서 새로 만들면 매번 처음부터 다시 시작한다.
@MainActor
private func makeExpiredThenRenewableModel(
    credentials: InMemoryCredentialStore,
    hints: InMemorySignInHintStore,
    responses: [ScriptedHTTP.Response]
) throws -> AppModel {
    let shared = ScriptedHTTP(responses)
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    return try makeModel(credentials: credentials, workflow: workflow,
                         signInHint: hints, http: { shared })
}

private func ok(_ body: String) -> ScriptedHTTP.Response {
    .init(status: 200, body: Data(body.utf8))
}

/// 인증에 성공할 때마다 모델이 필드 목록을 한 번 조회한다 — 스프린트 필드 ID를 찾으려는
/// 것이다(`AppModel.authenticate`). 이 테스트들은 스프린트를 보지 않으므로 빈 목록으로
/// 답하되, 대본에서 빼지는 않는다: 응답 하나는 실제로 소비되므로 생략하면 그 뒤 순서가
/// 통째로 밀려 미러가 비는 식으로 엉뚱하게 실패한다.
private let noSprintField = ok("[]")

private let unauthorized = ScriptedHTTP.Response(status: 401, body: Data("{}".utf8))
/// 스코프 토큰 폴백(`/_edge/tenant_info`)까지 막아 "진짜 자격증명 문제"로 확정시킨다.
private let cloudIdUnavailable = ScriptedHTTP.Response(status: 500, body: Data("{}".utf8))

/// 갱신에 성공하면 재로그인 없이 그 자리에서 `.ready`로 돌아오고, 새 토큰이 저장된다.
@MainActor
@Test func renewingTheTokenRecoversToReadyAndStoresTheNewToken() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "stale")
    )
    let hints = InMemorySignInHintStore()
    let model = try makeExpiredThenRenewableModel(
        credentials: creds, hints: hints,
        responses: [unauthorized, cloudIdUnavailable, ok(myselfBody), noSprintField,
                    ok(issuesBody(status: "To Do", assignee: "acc-me"))]
    )
    await model.start()
    #expect(model.phase == .expired)

    let renewed = await model.renewToken("fresh")

    #expect(renewed)
    #expect(model.phase == .ready)
    #expect(model.tokenRenewalMessage == nil)
    #expect(try creds.load()?.token == "fresh")
    #expect(try creds.load()?.email == "u@e.com", "이메일은 기억한 값을 그대로 쓴다")
}

/// 갱신이 거부되면 화면을 갈아엎지 않는다. `.expired`는 미러를 보여주는 단계이므로,
/// 실패를 로그인 화면으로 옮기면 사용자가 보고 있던 보드가 통째로 사라진다.
@MainActor
@Test func aRejectedRenewalKeepsTheExpiredScreenAndExplainsWhy() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "stale")
    )
    let hints = InMemorySignInHintStore()
    let model = try makeExpiredThenRenewableModel(
        credentials: creds, hints: hints,
        responses: [unauthorized, cloudIdUnavailable, unauthorized, cloudIdUnavailable]
    )
    await model.start()

    let renewed = await model.renewToken("also-bad")

    #expect(!renewed)
    #expect(model.phase == .expired, "실패해도 미러를 숨기지 않는다")
    #expect(model.tokenRenewalMessage != nil)
    #expect(try creds.load()?.token == "stale", "거부된 토큰을 저장하지 않는다")
}

/// 다시 시도해 성공하면 직전 실패 문구가 남으면 안 된다.
@MainActor
@Test func asuccessfulRetryClearsTheEarlierRenewalMessage() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "stale")
    )
    let hints = InMemorySignInHintStore()
    let model = try makeExpiredThenRenewableModel(
        credentials: creds, hints: hints,
        responses: [unauthorized, cloudIdUnavailable,
                    unauthorized, cloudIdUnavailable,
                    ok(myselfBody), noSprintField,
                    ok(issuesBody(status: "To Do", assignee: "acc-me"))]
    )
    await model.start()
    _ = await model.renewToken("also-bad")
    #expect(model.tokenRenewalMessage != nil)

    _ = await model.renewToken("fresh")

    #expect(model.tokenRenewalMessage == nil)
}

/// 갱신은 **같은 계정**으로 다시 인증하는 일이다. 계정 전환으로 오인해 스토어를
/// 초기화하면 이벤트 로그가 사라지고, 그건 다시 동기화해도 복구되지 않는다.
@MainActor
@Test func renewingKeepsTheMirrorAndTheEventLog() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let hints = InMemorySignInHintStore()
    let model = try makeExpiredThenRenewableModel(
        credentials: creds, hints: hints,
        responses: [ok(myselfBody), noSprintField,
                    ok(issuesBody(status: "To Do", assignee: "acc-me")),
                    unauthorized,
                    ok(myselfBody), noSprintField,
                    ok(issuesBody(status: "To Do", assignee: "acc-me"))]
    )
    await model.start()
    await model.syncNow()
    #expect(model.issues.map(\.key) == ["DEMO-1"], "먼저 미러가 채워져 있어야 검증이 성립한다")

    await model.syncNow()          // 401 — 토큰이 만료된 순간
    #expect(model.phase == .expired)

    _ = await model.renewToken("fresh")

    #expect(model.phase == .ready)
    #expect(model.issues.map(\.key) == ["DEMO-1"], "갱신이 미러를 버리면 안 된다")
}

/// `.expired`가 앱 시작 시점에 만들어졌으면 동기화 루프는 **아직 시작된 적이 없다**
/// (`RootView`는 `.expired`에서 회복할 때 루프를 걸지 않는다 — 그건 `performSync()`가
/// 스스로 회복한 경우를 위한 가드다). 갱신이 루프를 직접 걸지 않으면 사용자는
/// 성공 화면을 보고도 영영 동기화되지 않는 앱을 쓰게 된다.
@MainActor
@Test func renewingStartsTheSyncLoopItself() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "stale")
    )
    let hints = InMemorySignInHintStore()
    let model = try makeExpiredThenRenewableModel(
        credentials: creds, hints: hints,
        responses: [unauthorized, cloudIdUnavailable, ok(myselfBody), noSprintField,
                    ok(issuesBody(status: "To Do", assignee: "acc-me"))]
    )
    await model.start()
    #expect(!model.isSyncScheduled, "시작 시 만료된 경우 루프는 돌지 않는다")

    _ = await model.renewToken("fresh")

    #expect(model.isSyncScheduled, "갱신 뒤에는 주기 동기화가 돌아야 한다")
}

/// 기억한 값이 없으면 토큰만으로는 어디에 연결할지 알 수 없다. 조용히 실패하는 대신
/// 무엇을 해야 하는지 말한다.
@MainActor
@Test func renewingWithoutAHintFailsWithAnExplanation() async throws {
    let model = try makeModel(signInHint: InMemorySignInHintStore())

    let renewed = await model.renewToken("fresh")

    #expect(!renewed)
    #expect(model.tokenRenewalMessage != nil)
}

/// 빈 토큰은 요청을 보내기 전에 거른다 — 서버에 물어볼 것이 없다.
@MainActor
@Test func renewingWithABlankTokenIsRejectedLocally() async throws {
    let hints = InMemorySignInHintStore(
        seeded: SignInHint(site: "example.atlassian.net", email: "u@e.com").rawValue
    )
    let model = try makeModel(signInHint: hints)
    await model.start()

    let renewed = await model.renewToken("   ")

    #expect(!renewed)
    #expect(model.tokenRenewalMessage != nil)
}
