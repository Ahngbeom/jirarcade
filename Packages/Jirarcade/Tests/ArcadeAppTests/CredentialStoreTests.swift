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

/// 로그인 화면은 붙여넣기를 받는다. Atlassian API 토큰은 192자쯤 되는 긴 문자열이라
/// 웹에서 복사할 때 앞뒤에 공백이나 개행이 섞이는 일이 흔하고, `SecureField`는 값을
/// 가리므로 사용자가 눈으로 확인할 방법이 **전혀 없다**. 그 상태로 Basic 헤더를 만들면
/// `email:token ` 이 되어 401이 오고, 화면에는 "이메일 또는 토큰이 올바르지 않습니다"만
/// 뜬다 — 토큰은 정상인데도.
@Test func credentialsTrimPastedWhitespace() {
    let creds = Credentials(
        site: "  example.atlassian.net \n",
        email: " you@example.com\t",
        token: "\n  abc123token  \n"
    )
    #expect(creds.site == "example.atlassian.net")
    #expect(creds.email == "you@example.com")
    #expect(creds.token == "abc123token")
}

/// Keychain에서 읽는 경로도 이 이니셜라이저를 지난다. 이미 공백째로 저장해 버린
/// 자격증명이 있어도 다음 실행에서 스스로 복구돼야 한다 — 안 그러면 사용자는 재실행마다
/// 같은 실패를 겪으며 토큰을 몇 번이고 다시 발급받게 된다.
@Test func storedCredentialsWithWhitespaceRecoverOnLoad() throws {
    let store = InMemoryCredentialStore()
    try store.save(Credentials(site: "example.atlassian.net ", email: "u@e.com ", token: "tok "))
    let loaded = try store.load()
    #expect(loaded?.token == "tok")
    #expect(loaded?.email == "u@e.com")
}
