import Foundation
import Security

/// Jira 접속에 필요한 세 가지. 토큰은 물론 이메일도 로그에 남기지 않는다.
public struct Credentials: Sendable, Equatable, CustomStringConvertible {
    public let site: String
    public let email: String
    public let token: String

    public init(site: String, email: String, token: String) {
        self.site = site
        self.email = email
        self.token = token
    }

    public var description: String { "Credentials(site: \(site))" }
}

public protocol CredentialStore: Sendable {
    func load() throws -> Credentials?
    func save(_ credentials: Credentials) throws
    func clear() throws
}

public enum CredentialStoreError: Error, Equatable {
    /// Keychain이 예상치 못한 상태를 돌려줬다. 값은 OSStatus.
    case keychain(status: Int32)
    case malformedEntry
}

/// 테스트용. 실제 Keychain은 접근 권한 프롬프트를 띄우므로 테스트에서 쓰지 않는다.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var stored: Credentials?
    private let lock = NSLock()

    public init(seeded: Credentials? = nil) { self.stored = seeded }

    public func load() throws -> Credentials? { lock.withLock { stored } }
    public func save(_ credentials: Credentials) throws { lock.withLock { stored = credentials } }
    public func clear() throws { lock.withLock { stored = nil } }
}

/// macOS Keychain 구현. 사이트 주소를 서버로, 이메일을 계정으로, 토큰을 비밀로 저장한다.
public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "Jirarcade") { self.service = service }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service]
    }

    public func load() throws -> Credentials? {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status: status) }

        guard let entry = item as? [String: Any],
              let email = entry[kSecAttrAccount as String] as? String,
              let site = entry[kSecAttrLabel as String] as? String,
              let data = entry[kSecValueData as String] as? Data,
              let token = String(data: data, encoding: .utf8)
        else { throw CredentialStoreError.malformedEntry }

        return Credentials(site: site, email: email, token: token)
    }

    public func save(_ credentials: Credentials) throws {
        try clear()   // 갱신 대신 지우고 다시 넣는다 — 계정이 바뀌는 경우가 있다
        var query = baseQuery()
        query[kSecAttrAccount as String] = credentials.email
        query[kSecAttrLabel as String] = credentials.site
        query[kSecValueData as String] = Data(credentials.token.utf8)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status: status) }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status: status)
        }
    }
}
