import Testing
import Foundation
@testable import ArcadeApp

@Test func savedAccountIdComesBack() throws {
    let store = InMemoryAccountBindingStore()
    try store.save("acc-1")
    #expect(try store.load() == "acc-1")
}

@Test func emptyAccountBindingReturnsNil() throws {
    #expect(try InMemoryAccountBindingStore().load() == nil)
}

@Test func savingAccountIdTwiceReplaces() throws {
    let store = InMemoryAccountBindingStore()
    try store.save("acc-1")
    try store.save("acc-2")
    #expect(try store.load() == "acc-2")
}

/// `UserDefaults.standard`가 아니라 이 테스트만의 스위트를 써서, 다른 테스트나 앱의
/// 실제 `boundAccountId`와 상태를 공유하지 않는다.
@Test func userDefaultsBackedStoreRoundTrips() throws {
    let suiteName = "jirarcade-tests-account-binding-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = UserDefaultsAccountBindingStore(defaults: defaults)
    #expect(try store.load() == nil)

    try store.save("acc-1")
    #expect(try store.load() == "acc-1")

    try store.save("acc-2")
    #expect(try store.load() == "acc-2")
}

// MARK: - AccountBinding

@Test func bindingRoundTripsThroughItsRawValue() {
    let binding = AccountBinding(site: "example.atlassian.net", accountId: "acc-me")
    #expect(AccountBinding(rawValue: binding.rawValue) == binding)
}

/// 같은 사이트를 다르게 적어도 같은 바인딩이어야 한다 — 로그인 화면은 자유 입력이다.
@Test func bindingNormalizesTheSite() {
    let typed = AccountBinding(site: "HTTPS://Example.Atlassian.NET/", accountId: "acc-me")
    #expect(typed == AccountBinding(site: "example.atlassian.net", accountId: "acc-me"))
    #expect(typed.site == "example.atlassian.net")
}

/// 같은 accountId라도 사이트가 다르면 다른 계정이다 — Atlassian의 accountId는 사이트가
/// 아니라 Atlassian 계정에 붙기 때문에, 다른 조직의 Jira로 옮겨도 값이 그대로다.
@Test func sameAccountIdOnADifferentSiteIsNotTheSameAccount() {
    // 두 번째 사이트를 atlassian.net 밖의 호스트로 둔 이유: ModuleBoundaryTests가
    // 리포지토리 전체에서 예시 사이트 하나만 허용한다(실제 조직명 유출 방지).
    let first = AccountBinding(site: "example.atlassian.net", accountId: "acc-me")
    let second = AccountBinding(site: "jira.example.com", accountId: "acc-me")
    #expect(!first.identifiesSameAccount(as: second))
}

@Test func sameAccountIdOnTheSameSiteIsTheSameAccount() {
    let first = AccountBinding(site: "example.atlassian.net", accountId: "acc-me")
    let second = AccountBinding(site: "https://example.atlassian.net/", accountId: "acc-me")
    #expect(first.identifiesSameAccount(as: second))
}

@Test func differentAccountIdsAreNeverTheSameAccount() {
    let first = AccountBinding(site: "example.atlassian.net", accountId: "acc-first")
    let second = AccountBinding(site: "example.atlassian.net", accountId: "acc-second")
    #expect(!first.identifiesSameAccount(as: second))
}

/// 앱을 업데이트하기 전에 저장된 값은 accountId 하나뿐이다. 접두사가 없으므로 새 값과
/// 구분되고, 사이트는 "모름"으로 복원된다.
@Test func legacyRawValueDecodesAsAnAccountIdWithoutASite() {
    let legacy = AccountBinding(rawValue: "acc-me")
    #expect(legacy.site == nil)
    #expect(legacy.accountId == "acc-me")
    #expect(legacy.rawValue == "acc-me", "옛 값은 원래 형태 그대로 되돌아가야 한다")
}

/// 업데이트 직후의 핵심 조건: 사이트를 모르는 옛 값은 accountId만 비교한다. 이것을
/// "사이트가 다르다"로 읽으면 같은 계정을 쓰던 사용자가 이벤트 로그를 통째로 잃는다.
@Test func legacyBindingWithTheSameAccountIdIsTreatedAsTheSameAccount() {
    let legacy = AccountBinding(rawValue: "acc-me")
    let current = AccountBinding(site: "example.atlassian.net", accountId: "acc-me")
    #expect(legacy.identifiesSameAccount(as: current))
}

@Test func legacyBindingWithADifferentAccountIdIsStillASwitch() {
    let legacy = AccountBinding(rawValue: "acc-first")
    let current = AccountBinding(site: "example.atlassian.net", accountId: "acc-second")
    #expect(!legacy.identifiesSameAccount(as: current))
}

/// accountId에 구분자가 섞여도 사이트에서 **한 번만** 끊으므로 뒤쪽이 온전히 남는다.
@Test func accountIdContainingTheSeparatorSurvivesTheRoundTrip() {
    let binding = AccountBinding(site: "example.atlassian.net", accountId: "557058|weird|id")
    let restored = AccountBinding(rawValue: binding.rawValue)
    #expect(restored.accountId == "557058|weird|id")
    #expect(restored.site == "example.atlassian.net")
}

/// 접두사는 있는데 구분자가 없는 값(저장 중 잘림 등)은 사이트를 모르는 값으로 다룬다 —
/// 판단이 서지 않을 때 지우지 않는 쪽으로 기우는 원칙 그대로다.
@Test func truncatedRawValueDecodesConservatively() {
    let damaged = AccountBinding(rawValue: "v2|acc-me")
    #expect(damaged.site == nil)
    #expect(damaged.accountId == "acc-me")
}
