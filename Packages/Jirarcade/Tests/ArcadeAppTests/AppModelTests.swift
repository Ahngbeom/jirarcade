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

/// 세 번째 분기: 이전 자격증명을 못 읽으면(Keychain 장애 등) "전환 아님"으로 보수적으로
/// 판단해 미러를 남긴다. 오래된 미러는 다음 동기화로 복구되지만, 지운 이벤트 로그는
/// 복구되지 않는다 — 그래서 읽기 실패는 지우는 쪽이 아니라 남기는 쪽으로 기운다.
/// `loadError`만 세팅하고 `saveError`는 건드리지 않아, 이 테스트가 검증하는 게 "읽기
/// 실패" 하나뿐이라는 것과, 로그인이 인증 이후 단계까지 실제로 진행된다는 것을 확인한다.
@MainActor
@Test func unreadablePreviousCredentialsDoNotClearTheMirror() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "first@e.com", token: "t")
    )
    creds.loadError = CredentialStoreError.keychain(status: -25308)
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

    await model.signIn(site: "example.atlassian.net", email: "second@e.com", token: "t2")

    #expect(model.phase == .ready, "읽기 실패가 로그인 자체를 막으면 안 된다 — 인증 이후 단계까지 진행돼야 한다")
    #expect(try store.loadMirror().count == 1, "이전 자격증명을 못 읽으면 전환 여부를 알 수 없다 — 지우지 않는다")
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
            .init(status: 200, body: Data(issues.utf8)),       // syncNow의 검색
        ])
    })
    await model.start()
    #expect(model.phase == .ready)

    await model.syncNow()

    #expect(model.summary != nil)
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
            .init(status: 200, body: Data(issues.utf8)),
            .init(status: 500, body: Data("{}".utf8)),          // 두 번째 동기화는 실패
        ])
    })
    await model.start()
    await model.syncNow()
    let afterFirst = model.summary

    await model.syncNow()

    #expect(model.summary == afterFirst, "실패해도 마지막 상태가 남는다")
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
