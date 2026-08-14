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
