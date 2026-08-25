import Testing
import Foundation
import ArcadeCore
import JiraKit
@testable import ArcadeApp

@MainActor
@Test func startWithNoCredentialsGoesToSignedOut() async throws {
    let model = try makeModel()
    await model.start()
    #expect(model.phase == .signedOut(message: nil))
}

@MainActor
@Test func startWithCredentialsButNoMappingGoesToMapping() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    // /myself 성공 → field 조회 → 매핑 후보 조회 (빈 결과)
    let model = try makeModel(credentials: creds, http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data("[]".utf8)),
            .init(status: 200, body: Data(#"{"issues":[]}"#.utf8)),
        ])
    })
    await model.start()
    #expect(model.phase == .mappingWorkflow(candidates: []))
}

@MainActor
@Test func startWithCredentialsAndMappingGoesToReady() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(
        seeded: WorkflowMap(statusToStage: ["To Do": .backlog])
    )
    let model = try makeModel(credentials: creds, workflow: workflow)
    await model.start()
    #expect(model.phase == .ready)
}

@MainActor
@Test func startWithExpiredTokenGoesToExpiredNotSignedOut() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "stale")
    )
    let model = try makeModel(credentials: creds, http: { ScriptedHTTP(status: 401) })
    await model.start()
    #expect(model.phase == .expired, "토큰 만료로 미러를 숨기지 않는다")
}

@MainActor
@Test func startWithBrokenCredentialStoreShowsMessageInsteadOfSignedOutSilently() async throws {
    let creds = InMemoryCredentialStore()
    // 실제 Keychain 장애를 흉내낸다. "자격증명 없음"과 구분되어야 한다 — 구분하지 않으면
    // 사용자는 로그인 화면에서 다시 로그인해도 저장소가 고장난 채라 계속 실패한다.
    creds.loadError = CredentialStoreError.keychain(status: -25308)
    let model = try makeModel(credentials: creds)
    await model.start()

    guard case .signedOut(let message) = model.phase else {
        Issue.record("signedOut을 기대했으나 \(model.phase)")
        return
    }
    #expect(message != nil, "저장소 장애는 자격증명 없음(message: nil)과 달라야 한다")
}

/// site/email/token 중 어느 것도 실패 메시지에 나타나지 않는지 확인한다. 세 값 모두를,
/// 그리고 실패로 이어지는 서로 다른 경로 각각에서 확인해야 "이번 substring만 우연히
/// 없었다"가 아니라 "이 경로가 구조적으로 자격증명을 담지 않는다"는 것을 보증한다.
private func assertDoesNotLeak(
    _ message: String?, site: String, email: String, token: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let text = message ?? ""
    #expect(!text.isEmpty, sourceLocation: sourceLocation)
    #expect(!text.contains(site), sourceLocation: sourceLocation)
    #expect(!text.contains(email), sourceLocation: sourceLocation)
    #expect(!text.contains(token), sourceLocation: sourceLocation)
}

@MainActor
@Test func signInWithMalformedSiteReportsWithoutLeakingCredentials() async throws {
    let model = try makeModel()
    let site = "not a host"
    let email = "distinct-user@example.com"
    let token = "distinct-secret-token-value"
    await model.signIn(site: site, email: email, token: token)

    guard case .signedOut(let message) = model.phase else {
        Issue.record("signedOut을 기대했으나 \(model.phase)")
        return
    }
    assertDoesNotLeak(message, site: site, email: email, token: token)
}

@MainActor
@Test func signInWithBadCredentialsStaysSignedOutWithoutLeakingCredentials() async throws {
    let model = try makeModel(http: { ScriptedHTTP(status: 401) })
    let site = "example.atlassian.net"
    let email = "distinct-user@example.com"
    let token = "distinct-wrong-token-value"
    await model.signIn(site: site, email: email, token: token)

    guard case .signedOut(let message) = model.phase else {
        Issue.record("signedOut을 기대했으나 \(model.phase)")
        return
    }
    assertDoesNotLeak(message, site: site, email: email, token: token)
}

@MainActor
@Test func signInWithServerErrorStaysSignedOutWithoutLeakingCredentials() async throws {
    // 401(unauthorized)도 invalidSite도 아닌, catch-all로 떨어지는 경로.
    let model = try makeModel(http: { ScriptedHTTP(status: 500) })
    let site = "example.atlassian.net"
    let email = "distinct-user@example.com"
    let token = "distinct-server-error-token"
    await model.signIn(site: site, email: email, token: token)

    guard case .signedOut(let message) = model.phase else {
        Issue.record("signedOut을 기대했으나 \(model.phase)")
        return
    }
    assertDoesNotLeak(message, site: site, email: email, token: token)
}

@MainActor
@Test func successfulSignInStoresCredentials() async throws {
    let creds = InMemoryCredentialStore()
    let model = try makeModel(credentials: creds, http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data("[]".utf8)),
            .init(status: 200, body: Data(#"{"issues":[]}"#.utf8)),
        ])
    })
    await model.signIn(site: "example.atlassian.net", email: "u@e.com", token: "good")
    #expect(try creds.load()?.site == "example.atlassian.net")
}

@MainActor
@Test func signOutClearsCredentialsAndReturnsToSignedOut() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let model = try makeModel(credentials: creds, workflow: workflow)
    await model.start()

    await model.signOut()
    #expect(model.phase == .signedOut(message: nil))
    #expect(try creds.load() == nil)
}

@MainActor
@Test func confirmingMappingSavesItAndGoesToReady() async throws {
    let workflow = InMemoryWorkflowStore()
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let model = try makeModel(credentials: creds, workflow: workflow, http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data("[]".utf8)),
            .init(status: 200, body: Data(#"{"issues":[]}"#.utf8)),
        ])
    })
    await model.start()

    let map = WorkflowMap(statusToStage: ["To Do": .backlog, "Done": .done])
    await model.confirmMapping(map)

    #expect(model.phase == .ready)
    #expect(try workflow.load() == map)
}

@MainActor
@Test func partialMappingIsAllowedAndReported() async throws {
    let workflow = InMemoryWorkflowStore()
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let issues = #"""
    {"issues":[
      {"key":"DEMO-1","fields":{"summary":"a","status":{"name":"To Do"},
       "issuetype":{"name":"Task"},"updated":"2026-08-14T09:00:00.000+0000"}},
      {"key":"DEMO-2","fields":{"summary":"b","status":{"name":"Blocked"},
       "issuetype":{"name":"Task"},"updated":"2026-08-14T09:00:00.000+0000"}}
    ]}
    """#
    let model = try makeModel(credentials: creds, workflow: workflow, http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data("[]".utf8)),
            .init(status: 200, body: Data(issues.utf8)),
        ])
    })
    await model.start()

    #expect(model.phase == .mappingWorkflow(candidates: ["Blocked", "To Do"]))

    // "Blocked"를 일부러 비워둔 채 확정한다 — 강제하지 않는다.
    await model.confirmMapping(WorkflowMap(statusToStage: ["To Do": .backlog]))

    #expect(model.phase == .ready)
    #expect(model.unmappedStatuses == ["Blocked"], "매핑되지 않은 상태가 배지로 드러나야 한다")
}

/// I2: `confirmMapping`이 저장 실패를 삼키면 안 된다 — 삼키면 이후 모든 동기화가
/// 영구히 무동작(I1)이 되고, 재실행하면 마법사가 다시 뜨는데도 사용자는 이유를 모른다.
/// `credentialSaveWarning`과 대칭인 `workflowSaveWarning`으로 노출한다.
@MainActor
@Test func confirmMappingWithFailedSaveStillReachesReadyButWarns() async throws {
    let workflow = InMemoryWorkflowStore()
    workflow.saveError = StubError()
    let model = try makeModel(workflow: workflow)

    await model.confirmMapping(WorkflowMap(statusToStage: ["To Do": .backlog]))

    #expect(model.phase == .ready, "매핑을 강제하지 않는다는 원칙과 같은 이유로 마법사로 돌려보내지 않는다")
    #expect(model.workflowSaveWarning != nil)
}

@MainActor
@Test func confirmMappingWithSuccessfulSaveLeavesNoWarning() async throws {
    let workflow = InMemoryWorkflowStore()
    let model = try makeModel(workflow: workflow)

    await model.confirmMapping(WorkflowMap(statusToStage: ["To Do": .backlog]))

    #expect(model.workflowSaveWarning == nil)
}

@MainActor
@Test func signingInAsADifferentAccountClearsTheMirror() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "first@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    // myselfBody가 항상 accountId "acc-me"를 돌려주므로, "acc-me"와 다른 값으로 미리
    // 묶어 둬야 "계정이 바뀌었다"는 조건을 만든다.
    let accountBinding = InMemoryAccountBindingStore(seeded: "acc-first")
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    try store.applySync(
        issues: [ObservedIssue(key: "DEMO-1", summary: "s", statusName: "To Do",
                               issueType: "Task", priority: nil, assigneeAccountId: nil,
                               assigneeName: nil, dueDate: nil,
                               jiraUpdatedAt: iso("2026-08-14T09:00:00Z"))],
        events: [], observedAt: iso("2026-08-14T09:00:00Z")
    )
    #expect(try store.loadMirror().count == 1)

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let model = AppModel(
        store: store, credentials: creds, workflow: workflow, accountBinding: accountBinding,
        sprintField: InMemorySprintFieldStore(),
        clientFactory: { auth in
            JiraClient(auth: auth, http: ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 200, body: Data(#"{"issues":[]}"#.utf8)),
            ]))
        },
        clock: { iso("2026-08-14T09:00:00Z") }, calendar: utc
    )

    await model.signIn(site: "example.atlassian.net", email: "second@e.com", token: "t2")

    #expect(try store.loadMirror().isEmpty, "다른 계정의 XP와 섞이면 복구할 수 없다")
}

/// 비교가 반전되면(다른 계정인데 리셋 안 함) 위 테스트가 잡아낸다.
/// 비교 자체가 통째로 사라져 "무조건 리셋"이 되는 뮤테이션은 위 테스트만으로는 잡히지
/// 않는다 — 그 테스트는 어차피 미러가 비어 있길 기대하기 때문이다. 같은 계정으로 다시
/// 로그인했을 때 미러가 살아남는지를 확인해야 그 뮤테이션도 잡을 수 있다.
@MainActor
@Test func signingInAsTheSameAccountAgainKeepsTheMirror() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "same@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    // myselfBody와 같은 accountId로 미리 묶어 둔다 — "이미 이 계정으로 로그인해 있던" 상태.
    let accountBinding = InMemoryAccountBindingStore(seeded: "acc-me")
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    try store.applySync(
        issues: [ObservedIssue(key: "DEMO-1", summary: "s", statusName: "To Do",
                               issueType: "Task", priority: nil, assigneeAccountId: nil,
                               assigneeName: nil, dueDate: nil,
                               jiraUpdatedAt: iso("2026-08-14T09:00:00Z"))],
        events: [], observedAt: iso("2026-08-14T09:00:00Z")
    )
    #expect(try store.loadMirror().count == 1)

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let model = AppModel(
        store: store, credentials: creds, workflow: workflow, accountBinding: accountBinding,
        sprintField: InMemorySprintFieldStore(),
        clientFactory: { auth in
            JiraClient(auth: auth, http: ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
            ]))
        },
        clock: { iso("2026-08-14T09:00:00Z") }, calendar: utc
    )

    await model.signIn(site: "example.atlassian.net", email: "same@e.com", token: "new-token")

    #expect(try store.loadMirror().count == 1, "같은 계정으로 다시 로그인해도 미러를 지우면 안 된다")
}

/// 세 번째 분기: `accountBinding.load()`를 못 읽으면(Keychain/UserDefaults 장애 등)
/// "전환 아님"으로 보수적으로 판단해 미러를 남긴다. 오래된 미러는 다음 동기화로
/// 복구되지만, 지운 이벤트 로그는 복구되지 않는다 — 그래서 읽기 실패는 지우는 쪽이
/// 아니라 남기는 쪽으로 기운다.
@MainActor
@Test func unreadableAccountBindingDoesNotClearTheMirror() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "first@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let accountBinding = InMemoryAccountBindingStore(seeded: "acc-first")
    accountBinding.loadError = StubError()
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    try store.applySync(
        issues: [ObservedIssue(key: "DEMO-1", summary: "s", statusName: "To Do",
                               issueType: "Task", priority: nil, assigneeAccountId: nil,
                               assigneeName: nil, dueDate: nil,
                               jiraUpdatedAt: iso("2026-08-14T09:00:00Z"))],
        events: [], observedAt: iso("2026-08-14T09:00:00Z")
    )
    #expect(try store.loadMirror().count == 1)

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let model = AppModel(
        store: store, credentials: creds, workflow: workflow, accountBinding: accountBinding,
        sprintField: InMemorySprintFieldStore(),
        clientFactory: { auth in
            JiraClient(auth: auth, http: ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
            ]))
        },
        clock: { iso("2026-08-14T09:00:00Z") }, calendar: utc
    )

    await model.signIn(site: "example.atlassian.net", email: "second@e.com", token: "t2")

    #expect(model.phase == .ready, "읽기 실패가 로그인 자체를 막으면 안 된다 — 인증 이후 단계까지 진행돼야 한다")
    #expect(try store.loadMirror().count == 1, "바인딩을 못 읽으면 전환 여부를 알 수 없다 — 지우지 않는다")
}

/// C1의 핵심 회귀 테스트. v0.1의 유일한 로그아웃 경로(만료 배너의 "로그아웃" 버튼)로
/// 로그아웃한 뒤 다른 계정으로 로그인해도 미러와 이벤트 로그가 반드시 비어야 한다.
/// 이 수정 전에는 `signOut()`이 지우는 자격증명 저장소로 "계정이 바뀌었는지"를
/// 판단했기 때문에, 로그아웃 직후에는 그 판단 근거 자체가 사라져 리셋이 통째로
/// 건너뛰였다 — A의 XP가 B의 점수에 영구히 합산됐다.
@MainActor
@Test func signOutThenDifferentAccountClearsTheMirrorAndEventLog() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "first@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let accountBinding = InMemoryAccountBindingStore()
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!

    let firstAccountBody = #"{"accountId":"acc-first","displayName":"First"}"#
    let secondAccountBody = #"{"accountId":"acc-second","displayName":"Second"}"#
    // clientFactory가 호출마다 새 HTTP 스텁을 만든다 — start()의 myself 호출과
    // signIn()의 myself 호출이 서로 다른 계정의 accountId를 돌려줘야 하기 때문이다.
    var responses = [firstAccountBody, secondAccountBody]

    let model = AppModel(
        store: store, credentials: creds, workflow: workflow, accountBinding: accountBinding,
        sprintField: InMemorySprintFieldStore(),
        clientFactory: { auth in
            JiraClient(auth: auth, http: ScriptedHTTP(status: 200, body: responses.removeFirst()))
        },
        clock: { iso("2026-08-14T09:00:00Z") }, calendar: utc
    )

    // first@ 계정으로 시작한다 — accountBinding이 "acc-first"로 채워진다.
    await model.start()
    #expect(model.phase == .ready)

    // 미러 1건 + 이벤트 로그 1건을 심는다(실제 HTTP 동기화를 또 태우지 않고 직접).
    try store.applySync(
        issues: [ObservedIssue(key: "DEMO-1", summary: "s", statusName: "To Do",
                               issueType: "Task", priority: nil, assigneeAccountId: "acc-first",
                               assigneeName: nil, dueDate: nil,
                               jiraUpdatedAt: iso("2026-08-14T09:00:00Z"))],
        events: [DomainEvent(issueKey: "DEMO-1", kind: .appeared, fromStatus: nil,
                             toStatus: "To Do", observedAt: iso("2026-08-14T09:00:00Z"),
                             actorAccountId: "acc-first")],
        observedAt: iso("2026-08-14T09:00:00Z")
    )
    #expect(try store.loadMirror().count == 1)
    #expect(try store.loadEvents().count == 1)

    // v0.1의 유일한 로그아웃 경로: 만료 배너의 "로그아웃" 버튼.
    await model.signOut()
    await model.signIn(site: "example.atlassian.net", email: "second@e.com", token: "t2")

    #expect(try store.loadMirror().isEmpty, "A의 데이터가 B의 스토어에 남아 있다")
    #expect(try store.loadEvents().isEmpty, "점수는 이벤트 로그의 순수 함수다 — 로그가 남으면 XP가 섞인다")
}

@MainActor
@Test func signInWithFailedCredentialSaveStillReachesReadyButWarns() async throws {
    let creds = InMemoryCredentialStore()
    creds.saveError = CredentialStoreError.keychain(status: -25299)
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let model = try makeModel(credentials: creds, workflow: workflow)
    await model.signIn(site: "example.atlassian.net", email: "u@e.com", token: "t")

    #expect(model.phase == .ready, "인증은 이미 성공했으니 로그인 화면으로 돌려보내지 않는다")
    #expect(model.credentialSaveWarning != nil)
}

@MainActor
@Test func signInWithSuccessfulSaveLeavesNoWarning() async throws {
    let creds = InMemoryCredentialStore()
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let model = try makeModel(credentials: creds, workflow: workflow)
    await model.signIn(site: "example.atlassian.net", email: "u@e.com", token: "t")

    #expect(model.credentialSaveWarning == nil)
}

@MainActor
@Test func credentialSaveWarningDoesNotSurviveALaterSuccessfulSignIn() async throws {
    let creds = InMemoryCredentialStore()
    creds.saveError = CredentialStoreError.keychain(status: -25299)
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let model = try makeModel(credentials: creds, workflow: workflow)
    await model.signIn(site: "example.atlassian.net", email: "u@e.com", token: "t")
    #expect(model.credentialSaveWarning != nil)

    creds.saveError = nil
    await model.signIn(site: "example.atlassian.net", email: "u@e.com", token: "t2")
    #expect(model.credentialSaveWarning == nil)
}

@MainActor
@Test func syncUpdatesSummaryAndCounts() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let issues = #"""
    {"issues":[
      {"key":"DEMO-1","fields":{"summary":"a","status":{"name":"To Do"},
       "issuetype":{"name":"Task"},"updated":"2026-08-14T09:00:00.000+0000"}}
    ]}
    """#
    let model = try makeModel(credentials: creds, workflow: workflow, http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),   // start의 myself
            .init(status: 200, body: Data("[]".utf8)),         // start의 field
            .init(status: 200, body: Data(issues.utf8)),       // syncNow의 검색
        ])
    })
    await model.start()
    #expect(model.phase == .ready)

    await model.syncNow()

    #expect(model.lifetimeSummary != nil)
    #expect(model.lastSync != nil)
    #expect(model.observationDays == 1, "첫 성공 동기화가 관측 1일차를 만든다")
}

@MainActor
@Test func syncFailureDoesNotWipeTheMirror() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let issues = #"""
    {"issues":[
      {"key":"DEMO-1","fields":{"summary":"a","status":{"name":"To Do"},
       "issuetype":{"name":"Task"},"updated":"2026-08-14T09:00:00.000+0000"}}
    ]}
    """#
    let model = try makeModel(credentials: creds, workflow: workflow, http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data("[]".utf8)),           // start의 field
            .init(status: 200, body: Data(issues.utf8)),
            .init(status: 500, body: Data("{}".utf8)),          // 두 번째 동기화는 실패
        ])
    })
    await model.start()
    await model.syncNow()
    let afterFirst = model.lifetimeSummary

    await model.syncNow()

    #expect(model.lifetimeSummary == afterFirst, "실패해도 마지막 상태가 남는다")
    #expect(model.schedulerState.consecutiveFailures == 1)
}

@MainActor
@Test func unauthorizedDuringSyncMovesToExpired() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let model = try makeModel(credentials: creds, workflow: workflow, http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data("[]".utf8)),   // start의 field
            .init(status: 401, body: Data("{}".utf8)),
        ])
    })
    await model.start()
    await model.syncNow()

    #expect(model.phase == .expired)
    #expect(model.phase.showsMirror == true, "만료돼도 미러는 보인다")
}

/// `SyncEngine.sync()`가 던질 수 있는 에러 중 `JiraError.transitionRejected(reason:)`는
/// Jira 응답의 `errorMessages`를 그대로 담는다 — 예를 들어 검색 호출이 400을 받으면
/// 실제 사용자 이메일 같은 응답 본문 조각이 그 문자열 안에 들어올 수 있다.
/// `SyncScheduler.State.lastFailure`는 이 에러를 `String(describing:)`으로 그대로
/// 옮겨 UI가 읽으므로, 응답 본문이 화면까지 새면 안 된다. 이 테스트는 `performSync()`가
/// `JiraError`를 케이스 이름만 남기고 페이로드를 버리는지 고정한다 — 나중에 누군가
/// 무심코 원본 에러를 그대로 던지게 바꾸면 이 테스트가 잡는다.
@MainActor
@Test func syncFailureDoesNotLeakResponseContentIntoLastFailure() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let leakedEmail = "leaked-user@example.com"
    let errorBody = #"{"errorMessages":["JQL referenced unknown user \#(leakedEmail)"]}"#
    let model = try makeModel(credentials: creds, workflow: workflow, http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data("[]".utf8)),   // start의 field
            .init(status: 400, body: Data(errorBody.utf8)),   // 검색 호출이 응답 본문에 이메일을 담아 거부
        ])
    })
    await model.start()

    await model.syncNow()

    let failure = model.schedulerState.lastFailure
    #expect(failure != nil)
    #expect(failure?.contains(leakedEmail) == false, "Jira 응답 본문이 lastFailure로 새면 안 된다")
    #expect(failure == "JiraError.transitionRejected", "타입/케이스 이름만 남아야 한다")
}

/// I1: 로그인 전(만료 직후 등) client가 없는 상태에서 동기화를 시도하면, 요청이 아예
/// 나가지 않았으니 성공이 아니다. 예전에는 `performSync()`가 조용히 return해서
/// `SyncScheduler`가 이를 성공으로 오해하고 실패 이력과 쿨다운을 초기화했다.
@MainActor
@Test func syncAttemptWhileExpiredAtLaunchIsRecordedAsFailureNotSuccess() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "stale")
    )
    let model = try makeModel(credentials: creds, http: { ScriptedHTTP(status: 401) })
    await model.start()
    #expect(model.phase == .expired)

    await model.syncNow()

    #expect(model.schedulerState.consecutiveFailures == 1,
            "client가 없는 시도는 요청조차 나가지 않았다 — 성공으로 기록되면 안 된다")
    #expect(model.schedulerState.lastSyncAt == nil,
            "요청이 나가지 않았으니 마지막 동기화 시각도 갱신되면 안 된다")
}

/// I1의 두 번째 경로: 워크플로 매핑을 읽지 못하면(디스크 손상 등) 매 동기화가 영구히
/// 무동작이 된다. 예전에는 이 상태에서도 스케줄러가 계속 "성공"으로 기록해 실패
/// 배지가 영영 뜨지 않았다.
@MainActor
@Test func syncAttemptWithUnreadableWorkflowMapIsRecordedAsFailure() async throws {
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let model = try makeModel(credentials: creds, workflow: workflow)
    await model.start()
    #expect(model.phase == .ready)

    workflow.loadError = StubError()
    await model.syncNow()

    #expect(model.schedulerState.consecutiveFailures == 1,
            "매핑을 읽지 못해 요청이 나가지 않았다 — 성공으로 기록되면 안 된다")
}

/// 바인딩을 **읽지 못한** 상태에서 새 accountId를 쓰면, "전환 아님"으로 보수적으로 남겨둔
/// 이전 계정의 미러 위에 새 계정 바인딩이 덮인다. 다음 실행에서는 바인딩과 미러가 서로 다른
/// 계정을 가리키는데 검사는 통과하므로, 두 계정의 티켓과 이벤트가 한 스토어에 섞인다.
/// 읽기가 실패했다는 것은 저장소를 신뢰할 수 없다는 뜻이므로 쓰기도 하지 않는다.
@MainActor
@Test func unreadableAccountBindingDoesNotOverwriteTheBinding() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let accountBinding = InMemoryAccountBindingStore(seeded: "acc-first")
    accountBinding.loadError = StubError()
    let model = try makeModel(credentials: creds, accountBinding: accountBinding)

    await model.start()

    accountBinding.loadError = nil
    #expect(try accountBinding.load() == "acc-first",
            "읽지 못한 상태에서 덮어쓰면 다음 실행에서 계정 전환을 감지할 수 없다")
}

/// 매핑이 **없는 것**과 매핑을 **읽지 못한 것**은 다르다. 둘을 합치면 이미 설정을 끝낸
/// 사용자가 디스크 문제 한 번에 마법사로 되돌아가고, 화면 어디에도 이유가 없다.
/// 마법사로 보내는 것 자체는 같지만(매핑 없이는 모든 점수가 0이다) 왜 다시 묻는지는 남긴다.
@MainActor
@Test func unreadableWorkflowMappingIsNotMistakenForNoMapping() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    workflow.loadError = StubError()
    let model = try makeModel(credentials: creds, workflow: workflow)

    await model.start()

    #expect(model.workflowSaveWarning != nil,
            "매핑을 읽지 못해 다시 묻는다는 사실을 화면이 알려야 한다")
}

/// Atlassian의 **스코프 있는 API 토큰**은 사이트 직접 경로를 거부한다 — 엣지가 인증 단계
/// 이전에 401 + HTML 차단 페이지를 돌려준다. 토큰이 정상이고 이메일이 맞아도 마찬가지다.
/// 사용자에게 "어떤 종류의 토큰을 발급했나"는 답할 수 없는 질문이므로, 앱이 cloudId를
/// 조회해 `api.atlassian.com` 경로로 재시도한다.
@MainActor
@Test func scopedTokenFallsBackToTheCloudIdPath() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    // 같은 인스턴스를 공유해야 큐가 이어진다 — clientFactory는 폴백에서 두 번 호출된다.
    let scripted = ScriptedHTTP([
        .init(status: 401, body: Data()),                               // 사이트 직접 → 엣지 거부
        .init(status: 200, body: Data(#"{"cloudId":"cid-1"}"#.utf8)),   // tenant_info
        .init(status: 200, body: Data(myselfBody.utf8)),                // cloudId 경로 → 성공
    ])
    let model = try makeModel(credentials: creds, workflow: workflow, http: { scripted })

    await model.start()

    #expect(model.phase == .ready,
            "스코프 토큰이 cloudId 경로로 폴백해 로그인에 성공해야 한다")
}

/// 폴백이 자격증명 오류를 감춰서는 안 된다. 두 경로 모두 401이면 진짜 인증 실패다.
@MainActor
@Test func bothPathsFailingStillReportsBadCredentials() async throws {
    let scripted = ScriptedHTTP([
        .init(status: 401, body: Data()),                               // 사이트 직접
        .init(status: 200, body: Data(#"{"cloudId":"cid-1"}"#.utf8)),   // tenant_info
        .init(status: 401, body: Data()),                               // cloudId 경로도 거부
    ])
    let model = try makeModel(http: { scripted })

    await model.signIn(site: "example.atlassian.net", email: "u@e.com", token: "wrong")

    #expect(model.phase == .signedOut(message: "이메일 또는 토큰이 올바르지 않습니다."))
}

/// 남이 옮긴 전이는 동기화 경로에서도 0점이어야 한다(스펙 §4.2).
///
/// `AppModel`이 `SyncEngine`에 `myAccountId`를 넘기지 않던 시절, 이 경로만 실행자 필터를
/// 건너뛰어 `summary`가 `lifetimeSummary`보다 큰 XP를 보여줬다.
@MainActor
@Test func syncPathAppliesTheExecutorFilter() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(
        seeded: WorkflowMap(statusToStage: ["To Do": .backlog, "In Progress": .active])
    )
    let model = try makeModel(credentials: creds, workflow: workflow, http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data(issuesBody(status: "To Do", assignee: "acc-other").utf8)),
            .init(status: 200,
                  body: Data(issuesBody(status: "In Progress", assignee: "acc-other").utf8)),
        ])
    })
    await model.start()
    await model.syncNow()
    await model.syncNow()

    let summary = try #require(model.lifetimeSummary)
    // 위생 데일리 보너스는 이벤트와 무관하게 붙으므로 빼고 본다.
    #expect(summary.totalXP - summary.hygieneBonusXP == 0)
}

/// 같은 전이라도 내 계정이 담당이면 준다 — 위 테스트가 "전이 자체가 0점"이라는
/// 다른 이유로 통과하고 있지 않다는 것을 고정한다.
@MainActor
@Test func syncPathStillRewardsMyOwnTransitions() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(
        seeded: WorkflowMap(statusToStage: ["To Do": .backlog, "In Progress": .active])
    )
    let model = try makeModel(credentials: creds, workflow: workflow, http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data("[]".utf8)),   // start의 field
            .init(status: 200, body: Data(issuesBody(status: "To Do", assignee: "acc-me").utf8)),
            .init(status: 200,
                  body: Data(issuesBody(status: "In Progress", assignee: "acc-me").utf8)),
        ])
    })
    await model.start()
    await model.syncNow()
    await model.syncNow()

    let summary = try #require(model.lifetimeSummary)
    #expect(summary.totalXP - summary.hygieneBonusXP > 0)
}

/// 동기화가 끝나면 통산 요약이 **그 자리에서** 갱신된다. 예전에는 동기화 경로가 자기
/// 요약을 따로 담고 집계값은 다음 인증까지 옛 값에 머물러, 한 화면에 서로 다른 레벨이
/// 나란히 떴다. 갱신을 빠뜨리면 여기서 값이 재시작 후의 값과 어긋난다.
@MainActor
@Test func syncRefreshesTheLifetimeSummaryImmediately() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(
        seeded: WorkflowMap(statusToStage: ["To Do": .backlog, "In Progress": .active])
    )
    let store = try ArcadeStore(container: ArcadeStore.makeInMemoryContainer())
    // 내 티켓과 남의 티켓을 섞는다 — 전부 0점이면 이 비교가 아무것도 보장하지 못한다.
    let before = issuesBody(pairs: [("DEMO-1", "To Do", "acc-me"),
                                    ("DEMO-2", "To Do", "acc-other")])
    let after = issuesBody(pairs: [("DEMO-1", "In Progress", "acc-me"),
                                   ("DEMO-2", "In Progress", "acc-other")])
    let model = try makeModel(store: store, credentials: creds, workflow: workflow, http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data("[]".utf8)),   // start의 field
            .init(status: 200, body: Data(before.utf8)),
            .init(status: 200, body: Data(after.utf8)),
        ])
    })
    await model.start()
    await model.syncNow()
    await model.syncNow()
    let synced = try #require(model.lifetimeSummary)

    // 재시작: 같은 스토어를 다시 읽어 집계 경로가 처음부터 다시 계산한다.
    // 동기화 직후의 값이 이것과 다르면 화면이 옛 숫자를 보여주고 있었다는 뜻이다.
    await model.start()

    #expect(model.lifetimeSummary == synced)
    #expect(synced.totalXP - synced.hygieneBonusXP > 0, "내 전이의 XP는 남아 있어야 한다")
}

/// 계정이 바뀌면 채점 **입력**도 버린다.
///
/// `store.reset()`이 미러·이벤트·백필 run을 버리고 `signOut()`이 발견 목록을 비우는데
/// 워크플로 매핑만 남으면, 이전 조직에서 `statusCategory`로 추정한 (상태명 → 단계) 맵이
/// `effectiveWorkflow()`에 계속 병합된다. `Done`·`In Progress` 같은 흔한 이름이 겹치면
/// 새 계정의 전이가 남의 조직 추정으로 채점된다(리뷰 B2).
///
/// 사용자 매핑까지 버리는 이유: 남겨두면 `load() != nil`이라 다음 로그인에서 마법사가
/// 뜨지 않아 새 조직 상태를 설정할 기회가 사라진다.
@MainActor
@Test func signingInAsADifferentAccountClearsTheWorkflowMapping() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "first@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["Done": .done]))
    try workflow.saveFallbacks(WorkflowMap(statusToStage: ["In Progress": .active]))
    // myselfBody가 "acc-me"를 돌려주므로 다른 값으로 묶어 둬야 "계정이 바뀌었다"가 된다.
    let accountBinding = InMemoryAccountBindingStore(seeded: "acc-first")
    let model = try makeModel(credentials: creds, workflow: workflow,
                              accountBinding: accountBinding)

    await model.signIn(site: "example.atlassian.net", email: "second@e.com", token: "t2")

    let mapping = try workflow.load()
    let fallbacks = try workflow.loadFallbacks()
    #expect(mapping == nil, "남의 조직 상태 이름 체계를 새 계정에 물려주면 안 된다")
    #expect(fallbacks == nil, "폴백은 이전 조직 워크플로에 대한 추정이다")
}

/// 비교가 통째로 사라져 "무조건 삭제"가 되는 뮤테이션은 위 테스트로 잡히지 않는다 —
/// 그 테스트는 어차피 매핑이 비어 있길 기대하기 때문이다. 같은 계정으로 다시 로그인하면
/// 매핑이 살아남아야 한다(그 경로에서는 `store.reset()`도 불리지 않는다).
@MainActor
@Test func signingInAsTheSameAccountAgainKeepsTheWorkflowMapping() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "same@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["Done": .done]))
    try workflow.saveFallbacks(WorkflowMap(statusToStage: ["In Progress": .active]))
    let accountBinding = InMemoryAccountBindingStore(seeded: "acc-me")
    let model = try makeModel(credentials: creds, workflow: workflow,
                              accountBinding: accountBinding)

    await model.signIn(site: "example.atlassian.net", email: "same@e.com", token: "t")

    let mapping = try workflow.load()
    let fallbacks = try workflow.loadFallbacks()
    #expect(mapping?.statusToStage == ["Done": .done])
    #expect(fallbacks?.statusToStage == ["In Progress": .active])
}

/// N2. Atlassian Cloud의 accountId는 **사이트가 아니라 Atlassian 계정**에 붙는다 —
/// 회사 Jira에서 다른 조직의 Jira로 옮기면 같은 accountId가 돌아온다. accountId만
/// 비교하면 그 이동이 전환으로 잡히지 않아, 이전 조직의 미러·이벤트·워크플로 매핑이
/// 그대로 남고 새 조직의 전이가 남의 조직 기준으로 채점된다.
@MainActor
@Test func sameAccountOnADifferentSiteClearsTheMirrorAndMapping() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    // myselfBody가 돌려주는 accountId("acc-me")와 **같은** 값으로 묶어 둔다 — 사이트만
    // 다르다. accountId만 보는 구현은 이 테스트를 통과하지 못한다.
    let accountBinding = InMemoryAccountBindingStore(
        seeded: AccountBinding(site: "example.atlassian.net", accountId: "acc-me").rawValue
    )
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    try store.applySync(
        issues: [ObservedIssue(key: "DEMO-1", summary: "s", statusName: "To Do",
                               issueType: "Task", priority: nil, assigneeAccountId: nil,
                               assigneeName: nil, dueDate: nil,
                               jiraUpdatedAt: iso("2026-08-14T09:00:00Z"))],
        events: [DomainEvent(issueKey: "DEMO-1", kind: .appeared, fromStatus: nil,
                             toStatus: "To Do", observedAt: iso("2026-08-14T09:00:00Z"),
                             actorAccountId: "acc-me")],
        observedAt: iso("2026-08-14T09:00:00Z")
    )

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let model = AppModel(
        store: store, credentials: creds, workflow: workflow, accountBinding: accountBinding,
        sprintField: InMemorySprintFieldStore(),
        clientFactory: { auth in
            JiraClient(auth: auth, http: ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 200, body: Data(#"{"issues":[]}"#.utf8)),
            ]))
        },
        clock: { iso("2026-08-14T09:00:00Z") }, calendar: utc
    )

    // 두 번째 사이트를 atlassian.net 밖의 호스트로 둔 이유: ModuleBoundaryTests가
    // 리포지토리 전체에서 예시 사이트 하나만 허용한다(실제 조직명 유출 방지).
    await model.signIn(site: "jira.example.com", email: "u@e.com", token: "t")

    #expect(try store.loadMirror().isEmpty, "다른 조직의 티켓이 남으면 안 된다")
    #expect(try store.loadEvents().isEmpty, "이전 조직의 이벤트가 새 조직의 XP에 합산된다")
    #expect(try workflow.load() == nil,
            "이전 조직의 상태 매핑이 남으면 새 조직의 전이가 남의 기준으로 채점된다")
    #expect(try accountBinding.load()
            == AccountBinding(site: "jira.example.com", accountId: "acc-me").rawValue)
}

/// 업데이트 경로. 앱을 업데이트하기 전에 저장된 바인딩에는 accountId만 들어 있다.
/// 그 값을 "사이트가 다르다"로 읽으면 같은 사이트·같은 계정을 쓰던 사용자가 업데이트
/// 한 번에 이벤트 로그를 잃는다 — 이벤트 로그는 다시 동기화해도 복구되지 않는다.
@MainActor
@Test func legacyBindingFromAnOlderBuildDoesNotLookLikeAnAccountSwitch() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    // 옛 형식: 사이트 없이 accountId만.
    let accountBinding = InMemoryAccountBindingStore(seeded: "acc-me")
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    try store.applySync(
        issues: [ObservedIssue(key: "DEMO-1", summary: "s", statusName: "To Do",
                               issueType: "Task", priority: nil, assigneeAccountId: nil,
                               assigneeName: nil, dueDate: nil,
                               jiraUpdatedAt: iso("2026-08-14T09:00:00Z"))],
        events: [DomainEvent(issueKey: "DEMO-1", kind: .appeared, fromStatus: nil,
                             toStatus: "To Do", observedAt: iso("2026-08-14T09:00:00Z"),
                             actorAccountId: "acc-me")],
        observedAt: iso("2026-08-14T09:00:00Z")
    )

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let model = AppModel(
        store: store, credentials: creds, workflow: workflow, accountBinding: accountBinding,
        sprintField: InMemorySprintFieldStore(),
        clientFactory: { auth in
            JiraClient(auth: auth, http: ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
            ]))
        },
        clock: { iso("2026-08-14T09:00:00Z") }, calendar: utc
    )

    await model.start()

    #expect(model.phase == .ready)
    #expect(try store.loadMirror().count == 1, "업데이트만으로 미러를 지우면 안 된다")
    #expect(try store.loadEvents().count == 1, "업데이트만으로 이벤트 로그를 잃으면 안 된다")
    #expect(try workflow.load() != nil, "업데이트만으로 매핑을 다시 묻게 하면 안 된다")
    // 옛 값은 여기서 새 형식으로 승격된다 — 다음 로그인부터는 사이트까지 비교된다.
    #expect(try accountBinding.load()
            == AccountBinding(site: "example.atlassian.net", accountId: "acc-me").rawValue)
}

// MARK: - 궤도 스냅샷

private let orbitWorkflow = WorkflowMap(statusToStage: ["To Do": .backlog, "In Progress": .active])

/// `JiraTransition`은 `Decodable` 이니셜라이저만 공개돼 있다(`Sources/JiraKit/DTO.swift`).
/// `TransitionTests.swift`의 동명 헬퍼와 같은 모양이지만 `private`이라 파일을 넘어
/// 보이지 않으므로 이 파일에도 둔다.
private func jiraTransition(id: String, name: String, to status: String) throws -> JiraTransition {
    let body = """
    {"transitions":[{"id":"\(id)","name":"\(name)","to":{"name":"\(status)"}}]}
    """
    return try #require(JiraTransition.decodeList(Data(body.utf8)).first)
}

/// 뷰는 `Date()`를 부르지 않는다. 시계와 달력은 모델이 주입한다 —
/// `boardSnapshot`이 그렇게 하는 이유와 같다.
@MainActor
@Test func buildsAnOrbitSnapshotFromTheSameMirrorTheBoardUses() async throws {
    let workflow = InMemoryWorkflowStore(seeded: orbitWorkflow)
    let model = try makeModel(
        workflow: workflow,
        http: { ScriptedHTTP([.init(status: 200, body: Data(myselfBody.utf8))]) }
    )
    await model.signIn(site: "example.atlassian.net", email: "u@e.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    let orbit = model.orbitSnapshot(zoomProgress: 1)

    #expect(orbit.systems.map(\.statusName) == ["In Progress"])
    #expect(orbit.systems.first?.planets.map(\.id) == ["DEMO-1"])
}

/// 대기 중인 전이가 궤도에도 곧바로 보여야 한다. `issues`를 직접 읽으면
/// 카드에서 상태를 옮겨도 행성이 5초 동안 옛 태양에 남는다.
@MainActor
@Test func showsPendingTransitionsInTheOrbitImmediately() async throws {
    let workflow = InMemoryWorkflowStore(seeded: orbitWorkflow)
    let model = try makeModel(
        workflow: workflow,
        http: { ScriptedHTTP([.init(status: 200, body: Data(myselfBody.utf8))]) }
    )
    await model.signIn(site: "example.atlassian.net", email: "u@e.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "To Do")])

    model.requestTransition(issueKey: "DEMO-1",
                            transition: try jiraTransition(id: "1", name: "시작", to: "In Progress"))

    let orbit = model.orbitSnapshot(zoomProgress: 1)
    #expect(orbit.systems.map(\.statusName) == ["In Progress"])
}

/// 낙관적 사본이 스프린트 세 값을 떨어뜨리면, 상태를 옮기는 5초 동안
/// 카드의 이월 줄이 사라졌다가 돌아온다.
@MainActor
@Test func keepsSprintFactsWhileATransitionIsPending() async throws {
    let workflow = InMemoryWorkflowStore(seeded: orbitWorkflow)
    let model = try makeModel(
        workflow: workflow,
        http: { ScriptedHTTP([.init(status: 200, body: Data(myselfBody.utf8))]) }
    )
    await model.signIn(site: "example.atlassian.net", email: "u@e.com", token: "tok")
    model.seedIssuesForTesting([
        issue(key: "DEMO-1", status: "To Do", sprintCarryOvers: 4,
             firstSprintName: "DEMO 스프린트 (1)", latestSprintName: "DEMO 스프린트 (5)"),
    ])

    model.requestTransition(issueKey: "DEMO-1",
                            transition: try jiraTransition(id: "1", name: "시작", to: "In Progress"))

    let slot = model.boardSnapshot(minimumSpacing: 0)
        .lanes.flatMap(\.slots).first { $0.id == "DEMO-1" }
    #expect(slot?.sprintCarryOvers == 4)
    #expect(slot?.firstSprintName == "DEMO 스프린트 (1)")
    #expect(slot?.latestSprintName == "DEMO 스프린트 (5)")
}

// MARK: - 동기화 진행 표시

/// 동기화가 도는 동안 화면이 그 사실을 알 수 있어야 한다.
///
/// 이 값이 없으면 새로고침을 눌러도 아무 반응이 없어 앱이 멈춘 것처럼 보인다.
/// 백필은 `isBackfilling`으로 같은 일을 이미 하고 있다.
@MainActor
@Test func syncingRaisesAFlagTheScreenCanSee() async throws {
    let creds = InMemoryCredentialStore(seeded: .init(site: "example.atlassian.net",
                                                      email: "a@example.com", token: "t"))
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let model = try makeModel(credentials: creds, workflow: workflow, http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data("[]".utf8)),
            .init(status: 200, body: Data(#"{"issues":[]}"#.utf8)),
        ])
    })
    await model.start()

    #expect(!model.isSyncing, "동기화 전에는 꺼져 있다")
    await model.syncNow()
    #expect(!model.isSyncing, "동기화가 끝나면 다시 꺼진다")
}

/// 실패해도 표시가 꺼져야 한다. 켜진 채로 남으면 새로고침 버튼이 영영 비활성되고
/// 사용자는 앱을 다시 켜는 것 말고 할 수 있는 일이 없다.
@MainActor
@Test func syncingFlagClearsEvenWhenTheSyncFails() async throws {
    let creds = InMemoryCredentialStore(seeded: .init(site: "example.atlassian.net",
                                                      email: "a@example.com", token: "t"))
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let model = try makeModel(credentials: creds, workflow: workflow, http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data("[]".utf8)),
            .init(status: 500, body: Data()),                  // 검색 실패
        ])
    })
    await model.start()

    await model.syncNow()

    #expect(!model.isSyncing, "실패 경로에서도 반드시 꺼진다")
}
