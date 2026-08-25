import Foundation
import JiraKit

/// 스토어(미러·이벤트 로그·워크플로 매핑)가 묶여 있는 계정을 가리키는 값.
///
/// `accountId`만으로는 부족하다. Atlassian Cloud의 `accountId`는 **사이트가 아니라
/// Atlassian 계정**에 붙는다 — 같은 사람이 회사 Jira에서 다른 조직의 Jira로 옮기면
/// `accountId`는 그대로다. 사이트를 함께 보지 않으면 그 이동이 "계정 전환"으로 잡히지
/// 않고, 이전 조직의 워크플로 매핑과 백필 폴백 추정이 그대로 남아 새 조직의 전이를
/// 남의 조직 기준으로 채점한다. 미러와 이벤트도 두 조직 것이 한 스토어에 섞인다.
public struct AccountBinding: Equatable, Sendable {
    /// 옛 형식(`accountId`만 저장돼 있던 값)에서 복원하면 `nil`이다.
    /// 그 값이 어느 사이트에서 만들어졌는지는 알 방법이 없다.
    public let site: String?
    public let accountId: String

    /// 새 형식임을 표시하는 접두사. 옛 값은 `accountId` 하나뿐이라 이 접두사를 가질 수
    /// 없으므로, 이것만으로 옛 값과 새 값이 구분된다.
    private static let versionPrefix = "v2|"
    private static let separator: Character = "|"

    public init(site: String, accountId: String) {
        self.site = JiraSite.normalize(site)
        self.accountId = accountId
    }

    /// 저장된 값을 그대로 복원할 때 쓴다. 라벨이 `site:`와 다른 이유는 오버로드
    /// 해소를 사람이 읽어서 알 수 있게 하기 위해서다 — 이쪽은 정규화하지 않는다.
    private init(storedSite: String?, accountId: String) {
        self.site = storedSite
        self.accountId = accountId
    }

    /// 저장소에서 읽은 원시 문자열을 복원한다.
    ///
    /// 접두사가 없으면 앱을 업데이트하기 전에 저장된 옛 값이다 — 통째로 `accountId`로
    /// 보고 사이트는 모르는 것으로 둔다.
    public init(rawValue: String) {
        guard rawValue.hasPrefix(Self.versionPrefix) else {
            self.init(storedSite: nil, accountId: rawValue)
            return
        }
        let body = rawValue.dropFirst(Self.versionPrefix.count)
        // 사이트에서 **한 번만** 끊는다. `accountId`에 구분자가 섞여 있어도(Atlassian이
        // 형식을 바꾸더라도) 뒤쪽을 통째로 살리기 위해서다. 정규화된 사이트에는 `|`가
        // 들어갈 수 없다 — 그런 값은 `APITokenAuth.init`이 URL을 못 만들어 거른다.
        guard let cut = body.firstIndex(of: Self.separator) else {
            // 접두사는 있는데 구분자가 없다 — 저장 중 잘렸거나 손상됐다. 사이트를 모르는
            // 값으로 다룬다(아래 `identifiesSameAccount(as:)`가 보수적으로 판단한다).
            self.init(storedSite: nil, accountId: String(body))
            return
        }
        self.init(storedSite: String(body[body.startIndex..<cut]),
                  accountId: String(body[body.index(after: cut)...]))
    }

    /// 저장소에 넣을 원시 문자열. 옛 형식으로 복원한 값은 그대로 옛 형식으로 되돌아간다.
    public var rawValue: String {
        guard let site else { return accountId }
        return "\(Self.versionPrefix)\(site)\(Self.separator)\(accountId)"
    }

    /// 두 바인딩이 **같은 스토어를 계속 써도 되는** 같은 계정을 가리키는가.
    ///
    /// 한쪽이라도 사이트를 모르면(옛 형식) `accountId`만 비교한다. 앱을 업데이트하기
    /// 전에 저장된 값에는 사이트가 없는데, 그것을 "사이트가 다르다"로 읽으면 같은
    /// 사이트·같은 계정을 쓰던 기존 사용자가 업데이트 한 번에 이벤트 로그를 잃는다 —
    /// 이벤트 로그는 다시 동기화해도 복구되지 않는다. 판단이 서지 않을 때는 지우지 않는
    /// 쪽으로 기운다(`AppModel.validate()`의 읽기 실패 처리와 같은 원칙).
    ///
    /// 옛 값은 첫 로그인에서 새 형식으로 덮이므로, 이 관대한 비교는 업데이트 직후 한 번만
    /// 적용된다.
    public func identifiesSameAccount(as other: AccountBinding) -> Bool {
        guard accountId == other.accountId else { return false }
        guard let site, let otherSite = other.site else { return true }
        return site == otherSite
    }
}

/// 지금 스토어(미러·이벤트 로그)가 어느 계정에 묶여 있는지 기록한다. `AppModel.validate()`가
/// "계정이 바뀌었는가"를 판단하는 유일한 근거다.
///
/// 자격증명 저장소로는 이 판단을 할 수 없다 — `signOut()`이 정확히 그 저장소를 지우므로,
/// 로그아웃 뒤에는 "이전 계정이 무엇이었는지" 자격증명에서 더 이상 읽을 수 없다. 그래서 계정 식별자를 별도로, 로그아웃에도 살아남게 들고 다닌다.
///
/// 저장소는 문자열을 그대로 보관하기만 한다. 무엇이 담겨 있는지(그리고 옛 형식을 어떻게
/// 알아보는지)는 `AccountBinding.rawValue`가 정한다.
public protocol AccountBindingStore: Sendable {
    func load() throws -> String?
    func save(_ rawValue: String) throws
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

    /// 키 이름은 `boundAccountId` 그대로 둔다. 담기는 값의 형식이 넓어졌을 뿐이고,
    /// 키를 바꾸면 기존 사용자의 바인딩이 통째로 사라져 "바인딩 없음"이 된다.
    public init(key: String = "boundAccountId", defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    public func load() throws -> String? { defaults.string(forKey: key) }
    public func save(_ rawValue: String) throws { defaults.set(rawValue, forKey: key) }
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

    /// `seeded`는 **원시 문자열**이다 — 옛 형식(`"acc-me"`)도 새 형식
    /// (`AccountBinding(site:accountId:).rawValue`)도 그대로 심을 수 있어야,
    /// 업데이트 경로를 테스트에서 재현할 수 있다.
    public init(seeded: String? = nil) { self.stored = seeded }

    public func load() throws -> String? {
        if let loadError { throw loadError }
        return lock.withLock { stored }
    }

    public func save(_ rawValue: String) throws { lock.withLock { stored = rawValue } }
}
