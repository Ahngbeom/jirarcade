import Testing
import Foundation
import ArcadeCore
@testable import ArcadeApp

// MARK: - 값 타입

@Test func theHintNormalizesTheSiteAndTrimsTheEmail() {
    let hint = SignInHint(site: " https://example.atlassian.net/ ", email: " u@e.com\n")
    #expect(hint.site == "example.atlassian.net")
    #expect(hint.email == "u@e.com")
}

/// 저장 형식은 왕복해야 한다. 사이트는 정규화를 거쳐 `|`를 가질 수 없으므로
/// 첫 구분자에서 한 번만 끊는다 — 이메일 쪽에 구분자가 섞여도 통째로 살아남는다.
@Test func theHintRoundTripsThroughItsRawValue() {
    let hint = SignInHint(site: "example.atlassian.net", email: "u+tag@e.com")
    #expect(SignInHint(rawValue: hint.rawValue) == hint)
}

/// 손상된 값은 되살리지 않는다. 반쪽짜리 힌트로 "토큰만 갱신" 화면을 띄우면
/// 사용자가 틀린 계정으로 연결을 시도하게 된다.
@Test func amalformedRawValueDoesNotProduceAHint() {
    #expect(SignInHint(rawValue: "구분자가없다") == nil)
    #expect(SignInHint(rawValue: "|u@e.com") == nil, "사이트가 비었다")
    #expect(SignInHint(rawValue: "example.atlassian.net|") == nil, "이메일이 비었다")
    #expect(SignInHint(rawValue: "") == nil)
}

// MARK: - 모델 배선

@MainActor
@Test func signingInRemembersTheSiteAndEmail() async throws {
    let hints = InMemorySignInHintStore()
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let model = try makeModel(workflow: workflow, signInHint: hints)

    await model.signIn(site: "example.atlassian.net", email: "u@e.com", token: "t")

    #expect(model.phase == .ready)
    #expect(model.signInHint == SignInHint(site: "example.atlassian.net", email: "u@e.com"))
    #expect(try hints.load() != nil, "다음 실행에서도 읽을 수 있게 저장돼야 한다")
}

/// 로그아웃은 "Jira와 더 이상 말하지 않는다"이지 "나를 잊어라"가 아니다.
/// 힌트가 함께 지워지면 만료 → 로그아웃 → 재로그인 경로에서 사용자가 사이트 주소와
/// 이메일을 다시 쳐야 하고, 이 기능이 없애려던 수고가 그대로 돌아온다.
@MainActor
@Test func signingOutClearsTheTokenButKeepsTheHint() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let hints = InMemorySignInHintStore()
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let model = try makeModel(credentials: creds, workflow: workflow, signInHint: hints)
    await model.start()

    await model.signOut()

    #expect(try creds.load() == nil, "자격증명은 지운다")
    #expect(model.signInHint?.email == "u@e.com", "사이트·이메일은 남는다")
    #expect(try hints.load() != nil)
}

/// "다른 계정으로 연결"은 명시적으로 잊으라는 뜻이다 — 여기서만 힌트가 사라진다.
@MainActor
@Test func forgettingTheAccountClearsTheHintAsWell() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let hints = InMemorySignInHintStore()
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let model = try makeModel(credentials: creds, workflow: workflow, signInHint: hints)
    await model.start()

    await model.forgetAccount()

    #expect(model.phase == .signedOut(message: nil))
    #expect(model.signInHint == nil)
    #expect(try hints.load() == nil)
    #expect(try creds.load() == nil)
}

/// Keychain 항목이 통째로 사라진 '유실' 상황. 자격증명은 없지만 힌트는 남아 있으므로
/// 로그인 화면은 빈 폼이 아니라 '토큰만 갱신' 모드로 떠야 한다.
@MainActor
@Test func aLostKeychainEntryStillLeavesTheHintForTheSignInScreen() async throws {
    let hints = InMemorySignInHintStore(
        seeded: SignInHint(site: "example.atlassian.net", email: "u@e.com").rawValue
    )
    let model = try makeModel(credentials: InMemoryCredentialStore(), signInHint: hints)

    await model.start()

    #expect(model.phase == .signedOut(message: nil))
    #expect(model.signInHint?.site == "example.atlassian.net")
}

/// 이 기능이 생기기 전부터 쓰던 사용자에게는 힌트 저장소가 비어 있고 Keychain에만
/// 값이 있다. 그 사용자가 만료를 맞는 순간 힌트가 없으면 갱신 화면이 뜰 수 없으므로,
/// 자격증명을 읽는 시점에 힌트를 함께 채운다 — **검증 성공을 기다리지 않는다.**
@MainActor
@Test func loadingStoredCredentialsSeedsTheHintEvenWhenTheTokenIsExpired() async throws {
    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "stale")
    )
    let hints = InMemorySignInHintStore()
    let model = try makeModel(credentials: creds, signInHint: hints,
                              http: { ScriptedHTTP(status: 401) })

    await model.start()

    #expect(model.phase == .expired)
    #expect(model.signInHint == SignInHint(site: "example.atlassian.net", email: "u@e.com"))
    #expect(try hints.load() != nil, "다음 실행에서도 갱신 화면을 띄울 수 있어야 한다")
}

/// 힌트 저장소가 고장나도 로그인은 막지 않는다. 힌트는 편의이지 인증의 일부가 아니다.
@MainActor
@Test func aBrokenHintStoreDoesNotBlockSigningIn() async throws {
    let hints = InMemorySignInHintStore()
    hints.saveError = StubError()
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let model = try makeModel(workflow: workflow, signInHint: hints)

    await model.signIn(site: "example.atlassian.net", email: "u@e.com", token: "t")

    #expect(model.phase == .ready)
}
