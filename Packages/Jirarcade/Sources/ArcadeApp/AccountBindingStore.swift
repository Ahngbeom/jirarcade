import Foundation

/// 지금 스토어(미러·이벤트 로그)가 어느 계정에 묶여 있는지 기록한다. `AppModel.validate()`가
/// "계정이 바뀌었는가"를 판단하는 유일한 근거다.
///
/// 자격증명 저장소로는 이 판단을 할 수 없다 — `signOut()`이 정확히 그 저장소를 지우므로,
/// 로그아웃 뒤에는 "이전 계정이 무엇이었는지" 자격증명에서 더 이상 읽을 수 없다(v0.1 스펙
/// §8.2). 그래서 계정 식별자를 별도로, 로그아웃에도 살아남게 들고 다닌다.
public protocol AccountBindingStore: Sendable {
    func load() throws -> String?
    func save(_ accountId: String) throws
}

/// 실제 구현. Keychain이 아니라 UserDefaults를 쓰는 이유: 이 값은 비밀이 아니고,
/// 앱을 껐다 켜도 남아야 한다 — 로그아웃 후 앱을 종료했다가 다른 계정으로 로그인하는
/// 경로(quit → relaunch → sign in as B)도 리셋을 트리거해야 하기 때문이다.
/// `AppModel.appearancePreference`가 이미 같은 방식으로 UserDefaults.standard를 쓴다.
public struct UserDefaultsAccountBindingStore: AccountBindingStore {
    private let key: String
    // UserDefaults는 Sendable로 표시돼 있지 않지만 스레드 안전하다(Apple 문서).
    // `appearancePreference`가 이미 AppModel 안에서 UserDefaults.standard를 같은
    // 방식으로 다룬다.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(key: String = "boundAccountId", defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    public func load() throws -> String? { defaults.string(forKey: key) }
    public func save(_ accountId: String) throws { defaults.set(accountId, forKey: key) }
}

/// 테스트용. `UserDefaults.standard`를 직접 쓰면 프로세스 안의 다른 테스트와 상태를
/// 공유하게 되어(같은 키를 읽고 쓰는 여러 AppModel 인스턴스가 병렬로 테스트된다)
/// 실행 순서에 따라 결과가 달라질 수 있다 — 그래서 인스턴스별로 격리된 저장소를 쓴다.
public final class InMemoryAccountBindingStore: AccountBindingStore, @unchecked Sendable {
    private var stored: String?
    private let lock = NSLock()

    /// 설정하면 `load()`가 저장된 값 대신 이 에러를 던진다.
    /// Keychain 장애 등으로 바인딩을 읽지 못하는 상황을 흉내낸다.
    public var loadError: (any Error)?

    public init(seeded: String? = nil) { self.stored = seeded }

    public func load() throws -> String? {
        if let loadError { throw loadError }
        return lock.withLock { stored }
    }

    public func save(_ accountId: String) throws { lock.withLock { stored = accountId } }
}
