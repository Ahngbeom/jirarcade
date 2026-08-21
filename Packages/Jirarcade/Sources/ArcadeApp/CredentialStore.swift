import Foundation
import Security

/// Jira 접속에 필요한 세 가지. 토큰은 물론 이메일도 로그에 남기지 않는다.
public struct Credentials: Sendable, Equatable, CustomStringConvertible {
    public let site: String
    public let email: String
    public let token: String

    /// 세 값 모두 앞뒤 공백·개행을 떼어낸다.
    ///
    /// 로그인 화면은 붙여넣기를 받는다. Atlassian API 토큰은 192자쯤 되는 긴 문자열이라
    /// 웹에서 복사할 때 앞뒤에 공백이나 개행이 섞이는 일이 흔하고, `SecureField`는 값을
    /// 가리므로 사용자가 눈으로 확인할 방법이 **전혀 없다**. 그 상태로 Basic 헤더를 만들면
    /// `email:token ` 이 되어 서버가 401을 돌려주고, 화면에는 "이메일 또는 토큰이 올바르지
    /// 않습니다"만 뜬다 — 토큰은 정상인데도 진단이 불가능한 실패가 된다.
    ///
    /// Keychain에서 읽는 경로도 이 이니셜라이저를 지나므로, 이미 공백째로 저장해 버린
    /// 자격증명도 다음 실행에서 스스로 복구된다. 그러지 않으면 사용자는 재실행마다 같은
    /// 실패를 겪으며 토큰을 몇 번이고 다시 발급받게 된다.
    ///
    /// 세 값 중 어느 것도 앞뒤 공백이 의미를 갖지 않는다 — 호스트명, 이메일, base64 계열
    /// 토큰 모두 공백을 포함할 수 없는 형식이다.
    public init(site: String, email: String, token: String) {
        self.site = site.trimmingCharacters(in: .whitespacesAndNewlines)
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// 설정하면 `load()`가 저장된 값 대신 이 에러를 던진다.
    /// 실제 Keychain 장애(예: 잠긴 상태)와 "자격증명 없음"을 구분하는 호출부를 테스트하기 위함.
    public var loadError: (any Error)?
    /// 설정하면 `save(_:)`가 값을 저장하지 않고 이 에러를 던진다.
    public var saveError: (any Error)?

    public init(seeded: Credentials? = nil) { self.stored = seeded }

    public func load() throws -> Credentials? {
        if let loadError { throw loadError }
        return lock.withLock { stored }
    }

    public func save(_ credentials: Credentials) throws {
        if let saveError { throw saveError }
        lock.withLock { stored = credentials }
    }

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
