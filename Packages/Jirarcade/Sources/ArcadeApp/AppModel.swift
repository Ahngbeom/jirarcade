import Foundation
import ArcadeCore
import JiraKit

/// 앱 전체 상태를 소유한다. SwiftUI를 import하지 않으므로 화면 없이 테스트된다.
@Observable @MainActor
public final class AppModel {
    public private(set) var phase: Phase = .launching
    public private(set) var summary: PlayerSummary?
    public private(set) var lastSync: SyncRunSummary?
    public private(set) var observationDays: Int = 0
    public private(set) var unmappedStatuses: [String] = []
    /// 로그인은 성공했지만 자격증명을 저장하지 못했을 때 세팅된다. `phase`는 `.ready`로 계속
    /// 진행한다 — 사용자는 이미 인증됐으니 되돌려보내지 않되, 다음 실행에서 다시 로그인해야
    /// 할 수 있다는 사실을 화면이 보여줄 수 있게 한다.
    public private(set) var credentialSaveWarning: String?

    /// 외관 설정. UserDefaults에 저장되며 UI가 읽어 테마를 고른다.
    public var appearancePreference: AppearancePreference = .system {
        didSet { UserDefaults.standard.set(appearancePreference.rawValue, forKey: "appearance") }
    }

    private let store: ArcadeStore
    private let credentials: any CredentialStore
    private let workflow: any WorkflowStore
    private let clientFactory: (any AuthProvider) -> JiraClient
    private let clock: () -> Date
    private let calendar: Calendar
    private var scheduler: SyncScheduler?
    private let rules: RuleSet
    private let settings: AppSettings

    /// 로그인 후에만 존재한다. 매핑 조회와 동기화에 쓴다.
    private var client: JiraClient?

    /// 스케줄러의 실패 집계. UI가 "연결하지 못했습니다"를 언제 보여줄지 판단한다.
    public var schedulerState: SyncScheduler.State { scheduler?.state ?? .init() }

    public init(
        store: ArcadeStore,
        credentials: any CredentialStore,
        workflow: any WorkflowStore,
        clientFactory: @escaping (any AuthProvider) -> JiraClient,
        clock: @escaping () -> Date,
        calendar: Calendar,
        rules: RuleSet = .default,
        settings: AppSettings = .default
    ) {
        self.store = store
        self.credentials = credentials
        self.workflow = workflow
        self.clientFactory = clientFactory
        self.clock = clock
        self.calendar = calendar
        self.rules = rules
        self.settings = settings
        if let raw = UserDefaults.standard.string(forKey: "appearance"),
           let saved = AppearancePreference(rawValue: raw) {
            self.appearancePreference = saved
        }
    }

    /// 앱 시작. 저장된 자격증명이 있으면 확인하고 적절한 단계로 보낸다.
    public func start() async {
        phase = .launching
        let saved: Credentials?
        do {
            saved = try credentials.load()
        } catch {
            // 저장소가 고장난 것과 첫 실행(자격증명 없음)은 다르다 — 뭉개면 사용자가
            // 자기 상황을 알 수 없고, 로그인해도 같은 문제로 다시 실패할 수 있다.
            phase = .signedOut(message: "저장된 로그인 정보를 불러오지 못했습니다.")
            return
        }
        guard let saved else {
            phase = .signedOut(message: nil)
            return
        }
        await validate(saved, persistOnSuccess: false)
    }

    /// 로그인 화면에서 호출한다.
    public func signIn(site: String, email: String, token: String) async {
        phase = .validating
        credentialSaveWarning = nil
        await validate(Credentials(site: site, email: email, token: token), persistOnSuccess: true)
    }

    public func signOut() async {
        try? credentials.clear()
        client = nil
        summary = nil
        lastSync = nil
        credentialSaveWarning = nil
        phase = .signedOut(message: nil)
    }

    /// 매핑 마법사에서 "시작하기"를 눌렀을 때. 매핑은 강제하지 않으므로
    /// 일부 상태가 비어 있어도 받아들이고, 남은 것을 배지로 알린다.
    public func confirmMapping(_ map: WorkflowMap) async {
        try? workflow.save(map)
        refreshUnmapped(against: map)
        phase = .ready
    }

    /// 미러에 있는 상태 중 매핑되지 않은 것을 다시 센다.
    public func refreshUnmapped() {
        guard let map = try? workflow.load() else {
            unmappedStatuses = []
            return
        }
        refreshUnmapped(against: map)
    }

    /// 한 번 동기화한다. 스케줄러를 거치므로 중복 실행과 쿨다운 규칙이 적용된다.
    public func syncNow(reason: SyncReason = .manual) async {
        await ensureScheduler().requestSync(reason: reason)
    }

    /// 주기 동기화를 시작한다. ready 단계에서만 의미가 있다.
    public func startSyncing() {
        ensureScheduler().start()
    }

    public func stopSyncing() {
        scheduler?.stop()
    }

    private func ensureScheduler() -> SyncScheduler {
        if let scheduler { return scheduler }
        let created = SyncScheduler(
            settings: settings,
            clock: clock,
            perform: { [weak self] in try await self?.performSync() }
        )
        scheduler = created
        return created
    }

    /// 실제 동기화 한 번. 실패는 그대로 던져 스케줄러가 집계하게 둔다.
    ///
    /// `SyncScheduler.State.lastFailure`는 여기서 던진 에러를 `String(describing:)`으로
    /// 그대로 UI가 읽을 수 있는 문자열에 담는다(SyncScheduler.swift 참고). `JiraError`는
    /// 페이로드 없이 설계됐지만(`invalidSite`가 사이트 값을 담지 않는 것과 같은 이유)
    /// `.transitionRejected(reason:)`는 Jira 응답의 `errorMessages`를 그대로 담고,
    /// `.decoding(context:)`는 디코더의 `debugDescription`을 감싼다 — 둘 다 응답 본문
    /// 조각(이메일 등)을 실어 나를 수 있다. `DecodingError`·`URLError`가 그대로 새어나가는
    /// 경우도 마찬가지다. 그래서 `.unauthorized`를 제외한 모든 에러를 스케줄러에 닿기 전에
    /// `SyncFailure`로 한 번 줄인다 — 진단에는 타입/케이스 이름으로 충분하고, 본문은 필요 없다.
    private func performSync() async throws {
        // `try?`가 Optional을 평탄화하므로(SE-0230) 바인딩은 한 번이면 된다.
        guard let client, let map = try? workflow.load() else { return }

        let engine = SyncEngine(
            source: JiraIssueSource(client: client),
            store: store, rules: rules, workflow: map, calendar: calendar
        )
        do {
            let outcome = try await engine.sync(
                jql: "assignee = currentUser() AND statusCategory != Done",
                now: clock()
            )
            summary = outcome.summary
            if phase == .expired { phase = .ready }   // 재인증 없이 회복된 경우
        } catch JiraError.unauthorized {
            phase = .expired
            throw JiraError.unauthorized
        } catch {
            throw SyncFailure(redacting: error)
        }

        lastSync = try? store.loadSyncRuns().last
        observationDays = (try? store.observationDayCount(now: clock(), calendar: calendar)) ?? 0
        refreshUnmapped()
    }

    private func refreshUnmapped(against map: WorkflowMap) {
        let names = (try? store.loadMirror().values.map(\.statusName)) ?? []
        let fromMirror = map.unmappedStatuses(in: names)
        // 미러가 비어 있으면 방금 조회한 후보를 기준으로 센다.
        if fromMirror.isEmpty, case .mappingWorkflow(let candidates) = phase {
            unmappedStatuses = map.unmappedStatuses(in: candidates)
        } else {
            unmappedStatuses = fromMirror
        }
    }

    // MARK: - 내부

    private func validate(_ creds: Credentials, persistOnSuccess: Bool) async {
        let auth: APITokenAuth
        do {
            auth = try APITokenAuth(site: creds.site, email: creds.email, token: creds.token)
        } catch {
            phase = .signedOut(message: "사이트 주소를 확인해 주세요.")
            return
        }

        let candidate = clientFactory(auth)
        do {
            _ = try await candidate.myself()
        } catch JiraError.unauthorized {
            // 저장된 자격증명이 만료된 경우와 새 입력이 틀린 경우를 구분한다.
            phase = persistOnSuccess
                ? .signedOut(message: "이메일 또는 토큰이 올바르지 않습니다.")
                : .expired
            return
        } catch {
            phase = .signedOut(message: "Jira에 연결하지 못했습니다.")
            return
        }

        client = candidate
        if persistOnSuccess {
            // 다른 계정으로 갈아타면 미러와 이벤트 로그를 버린다 (v0.1 스펙 §8.2).
            // 남의 XP와 내 XP가 섞이면 복구할 수 없다.
            // 여기서는 `try?`가 맞다 — 이전 자격증명을 못 읽으면 "전환 아님"으로 보수적으로
            // 판단해 미러를 남긴다. 지우는 쪽이 되돌릴 수 없는 방향이기 때문이다.
            if let previous = try? credentials.load(), previous.email != creds.email {
                try? store.reset()
            }
            do {
                try credentials.save(creds)
            } catch {
                // 인증은 이미 성공했다 — 사용자를 로그인 화면으로 돌려보내지 않는다.
                // 대신 저장 실패를 화면이 보여줄 수 있게 남겨 둔다. 조용히 삼키면 다음 실행에서
                // 자격증명이 없어 로그아웃된 이유를 사용자가 알 방법이 없다.
                credentialSaveWarning = "로그인 정보를 저장하지 못했습니다. 앱을 다시 시작하면 로그인이 풀릴 수 있습니다."
            }
        }
        await routeAfterAuthentication()
    }

    /// 인증이 끝난 뒤 매핑 유무로 갈린다.
    private func routeAfterAuthentication() async {
        if (try? workflow.load()) != nil {
            phase = .ready
            return
        }
        phase = .mappingWorkflow(candidates: await mappingCandidates())
    }

    /// 매핑 후보는 내 티켓 조회 한 번에서 얻는다.
    /// **이 조회는 미러에 저장하지 않는다** — 매핑 전에 만든 이벤트는 0점으로 굳는다.
    private func mappingCandidates() async -> [String] {
        guard let client else { return [] }
        let source = JiraIssueSource(client: client)
        guard let result = try? await source.fetchAssignedIssues(
            jql: "assignee = currentUser() AND statusCategory != Done"
        ) else { return [] }
        return Set(result.issues.map(\.statusName)).sorted()
    }
}

/// `performSync()`가 던지는, 이미 안전하게 줄여둔 실패. `SyncScheduler`는 이 문자열을
/// `String(describing:)`으로 그대로 `lastFailure`에 담아 UI가 읽으므로, 여기 담기는 순간
/// 그 값은 화면에 노출될 수 있는 것으로 취급한다. 실제 축약은 `JiraKit`의
/// `redactedErrorDescription(_:)` 하나뿐이다 — `SyncEngine`이 동기화 이력에 적을 때도
/// 같은 함수를 쓰므로, 이 두 곳이 서로 다른 기준으로 새는 일이 없다.
private struct SyncFailure: Error, CustomStringConvertible {
    let description: String

    init(redacting error: Error) {
        description = redactedErrorDescription(error)
    }
}
