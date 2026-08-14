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
@Test func signInWithMalformedSiteReportsWithoutLeakingCredentials() async throws {
    let model = try makeModel()
    await model.signIn(site: "not a host", email: "u@e.com", token: "secret-token")

    guard case .signedOut(let message) = model.phase else {
        Issue.record("signedOut을 기대했으나 \(model.phase)")
        return
    }
    let text = message ?? ""
    #expect(!text.isEmpty)
    #expect(!text.contains("secret-token"))
    #expect(!text.contains("u@e.com"))
}

@MainActor
@Test func signInWithBadCredentialsStaysSignedOut() async throws {
    let model = try makeModel(http: { ScriptedHTTP(status: 401) })
    await model.signIn(site: "example.atlassian.net", email: "u@e.com", token: "wrong")

    guard case .signedOut(let message) = model.phase else {
        Issue.record("signedOut을 기대했으나 \(model.phase)")
        return
    }
    #expect(message != nil)
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
