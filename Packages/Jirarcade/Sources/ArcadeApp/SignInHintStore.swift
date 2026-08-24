import Foundation
import JiraKit

/// 다시 연결할 때 사용자가 **다시 치지 않아도 되는 것**: 사이트 주소와 이메일.
///
/// Atlassian은 2024-12-15부터 API 토큰을 만료시키므로(`AtlassianLinks` 참고) 모든
/// 사용자가 언젠가 재연결을 겪는다. 그때 바뀌는 것은 토큰 하나뿐인데, 자격증명 저장소는
/// 셋을 한 항목으로 묶어 두고 `signOut()`이 그 항목을 통째로 지운다 — 결과적으로 토큰
/// 하나 때문에 사이트와 이메일까지 다시 입력하게 된다. 그 둘만 따로 들고 다닌다.
///
/// 비밀이 아니므로 Keychain이 아니라 UserDefaults에 둔다. 그것이 핵심이기도 하다 —
/// Keychain 항목 자체가 사라진 '유실' 상황을 복구하려면 힌트가 **Keychain 밖에** 있어야
/// 한다. `AccountBinding`이 사이트를 UserDefaults에 남기는 것과 같은 판단이다.
public struct SignInHint: Equatable, Sendable {
    public let site: String
    public let email: String

    /// 사이트는 `JiraSite.normalize`를 거친다 — 힌트로 채운 폼이 그대로 다시 제출되므로,
    /// 여기서 정규화해 두지 않으면 사용자가 처음 입력한 형태(`https://…/`)가 계정 바인딩
    /// 비교에 그대로 흘러든다.
    public init(site: String, email: String) {
        self.site = JiraSite.normalize(site)
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 저장된 값을 그대로 복원한다. 이미 정규화를 거친 값이므로 다시 처리하지 않는다.
    private init(storedSite: String, storedEmail: String) {
        self.site = storedSite
        self.email = storedEmail
    }

    /// 사이트는 정규화를 거쳐 `|`를 가질 수 없으므로 **첫** 구분자에서 한 번만 끊는다.
    /// 뒤쪽은 통째로 이메일이다.
    ///
    /// 한쪽이라도 비어 있으면 되살리지 않는다 — 반쪽짜리 힌트로 '토큰만 갱신' 화면을
    /// 띄우면 사용자가 어디로 연결되는지 모른 채 토큰을 넣게 된다.
    public init?(rawValue: String) {
        guard let cut = rawValue.firstIndex(of: Self.separator) else { return nil }
        let site = String(rawValue[..<cut])
        let email = String(rawValue[rawValue.index(after: cut)...])
        guard !site.isEmpty, !email.isEmpty else { return nil }
        self.init(storedSite: site, storedEmail: email)
    }

    public var rawValue: String { "\(site)\(Self.separator)\(email)" }

    private static let separator: Character = "|"
}

/// 저장소는 문자열을 보관하기만 한다. 형식은 `SignInHint.rawValue`가 정한다 —
/// `AccountBindingStore`와 같은 모양이다.
public protocol SignInHintStore: Sendable {
    func load() throws -> String?
    func save(_ rawValue: String) throws
    func clear() throws
}

public struct UserDefaultsSignInHintStore: SignInHintStore {
    private let key: String
    // UserDefaults는 Sendable로 표시돼 있지 않지만 스레드 안전하다(Apple 문서).
    // `UserDefaultsAccountBindingStore`가 이미 같은 방식으로 다룬다.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(key: String = "signInHint", defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    public func load() throws -> String? { defaults.string(forKey: key) }
    public func save(_ rawValue: String) throws { defaults.set(rawValue, forKey: key) }
    public func clear() throws { defaults.removeObject(forKey: key) }
}

/// 테스트용. `UserDefaults.standard`를 쓰면 병렬로 도는 다른 테스트와 같은 키를
/// 공유해 실행 순서에 따라 결과가 달라진다.
public final class InMemorySignInHintStore: SignInHintStore, @unchecked Sendable {
    private var stored: String?
    private let lock = NSLock()

    /// 설정하면 `save(_:)`가 이 에러를 던진다. 힌트 저장 실패가 로그인 자체를 막지
    /// 않는지 확인하는 데 쓴다.
    public var saveError: (any Error)?

    public init(seeded: String? = nil) { self.stored = seeded }

    public func load() throws -> String? { lock.withLock { stored } }

    public func save(_ rawValue: String) throws {
        if let saveError { throw saveError }
        lock.withLock { stored = rawValue }
    }

    public func clear() throws { lock.withLock { stored = nil } }
}
