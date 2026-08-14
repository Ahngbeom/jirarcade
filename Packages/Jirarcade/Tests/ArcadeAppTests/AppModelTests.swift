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
    // /myself 성공 → 매핑 후보 조회 (빈 결과)
    let model = try makeModel(credentials: creds, http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
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

@MainActor
@Test func signingInAsADifferentAccountClearsTheMirror() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "first@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
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
        store: store, credentials: creds, workflow: workflow,
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

/// 이메일 비교가 반전되면(다른 계정인데 리셋 안 함) 위 테스트가 잡아낸다.
/// 비교 자체가 통째로 사라져 "무조건 리셋"이 되는 뮤테이션은 위 테스트만으로는 잡히지
/// 않는다 — 그 테스트는 어차피 미러가 비어 있길 기대하기 때문이다. 같은 계정으로 다시
/// 로그인했을 때 미러가 살아남는지를 확인해야 그 뮤테이션도 잡을 수 있다.
@MainActor
@Test func signingInAsTheSameAccountAgainKeepsTheMirror() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "same@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
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
        store: store, credentials: creds, workflow: workflow,
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
