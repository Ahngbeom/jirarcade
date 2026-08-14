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
