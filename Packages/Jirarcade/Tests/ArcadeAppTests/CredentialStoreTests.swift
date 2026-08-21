import Testing
@testable import ArcadeApp

@Test func savedCredentialsComeBack() throws {
    let store = InMemoryCredentialStore()
    let creds = Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    try store.save(creds)
    #expect(try store.load() == creds)
}

@Test func emptyStoreReturnsNil() throws {
    #expect(try InMemoryCredentialStore().load() == nil)
}

@Test func clearRemovesEverything() throws {
    let store = InMemoryCredentialStore()
    try store.save(Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t"))
    try store.clear()
    #expect(try store.load() == nil)
}

@Test func savingTwiceReplacesRatherThanDuplicates() throws {
    let store = InMemoryCredentialStore()
    try store.save(Credentials(site: "first.example.com", email: "a@e.com", token: "1"))
    try store.save(Credentials(site: "second.example.com", email: "b@e.com", token: "2"))
    #expect(try store.load()?.site == "second.example.com")
}

@Test func descriptionNeverLeaksCredentials() {
    let creds = Credentials(site: "example.atlassian.net", email: "u@e.com", token: "secret-token")
    let text = String(describing: creds)
    #expect(!text.contains("secret-token"))
    #expect(!text.contains("u@e.com"))
}
