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
    /// 매핑은 성공했지만 저장하지 못했을 때 세팅된다. `credentialSaveWarning`과 같은 이유로
    /// 조용히 삼키지 않는다 — 그러지 않으면 모든 동기화가 영구히 무동작(I1)이 되는데
    /// 사용자는 그 사실을 알 방법이 없다.
    public private(set) var workflowSaveWarning: String?

    /// 진행 중이던 동기화가 로그아웃·계정 전환을 가로질러 스토어에 쓰지 않도록 막는 데
    /// 쓰는 세대 값. 인증에 성공할 때(로그인/시작)와 로그아웃할 때마다 올라간다.
    /// `performSync()`가 호출 시점의 값을 캡처해 `SyncEngine.sync(isStillCurrent:)`에
    /// 건네고, 페치가 끝난 시점에 세대가 그대로인지 확인한다.
    private var syncGeneration = 0

    /// 외관 설정. UserDefaults에 저장되며 UI가 읽어 테마를 고른다.
    public var appearancePreference: AppearancePreference = .system {
        didSet { UserDefaults.standard.set(appearancePreference.rawValue, forKey: "appearance") }
    }

    private let store: ArcadeStore
    private let credentials: any CredentialStore
    private let workflow: any WorkflowStore
    private let accountBinding: any AccountBindingStore
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
        accountBinding: any AccountBindingStore,
        clientFactory: @escaping (any AuthProvider) -> JiraClient,
        clock: @escaping () -> Date,
        calendar: Calendar,
        rules: RuleSet = .default,
        settings: AppSettings = .default
    ) {
        self.store = store
        self.credentials = credentials
        self.workflow = workflow
        self.accountBinding = accountBinding
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
        // 로그아웃의 첫 번째 의미는 "Jira와 더 이상 말하지 않는다"이다 — 자격증명/phase를
        // 지우기 전에 먼저 루프를 멈춘다. client를 nil로 만들기만 해서는 부족하다: 루프가
        // 계속 돌면 매 틱마다 performSync()가 `guard let client`에서 조용히 return할 뿐
        // 깨어나기는 계속 깨어나 — 로그아웃 후에도 타이머가 무한히 도는 낭비가 남는다.
        //
        // stopSyncing()만으로는 부족하다 — SyncScheduler.State(연속 실패 횟수, 마지막 실패
        // 메시지, shouldSurfaceFailure)는 stop()이 지우지 않는다(의도적으로: stop()은 실패
        // 이력을 기억한 채로 멈추는 "일시정지"다). scheduler 인스턴스를 통째로 버려야
        // 이 계정에 대한 실패 이력도 함께 버려진다 — 안 그러면 다른 계정으로 로그인했을 때도
        // 이전 계정의 "Jira에 연결하지 못했습니다" 배지와 백오프 지연이 그대로 넘어온다.
        // 이건 계정을 바꿀 때 미러/이벤트 로그를 버리는 것(validate() 참고)과 같은 종류의
        // 정리이므로 여기서도 함께 처리한다. ensureScheduler()는 scheduler가 nil이면 새로
        // 만드므로 다음 로그인에서 자연히 깨끗한 상태로 시작한다.
        stopSyncing()
        scheduler = nil
        // 세대를 올려 진행 중이던 페치가 끝나도 이 계정의 스토어에 쓰지 못하게 막는다
        // (I4). `boundAccountId`는 여기서 지우지 않는다 — 지우면 다음 로그인이 "계정이
        // 바뀌었는지" 판단할 근거를 잃는다. validate() 참고.
        syncGeneration += 1
        try? credentials.clear()
        client = nil
        summary = nil
        lastSync = nil
        credentialSaveWarning = nil
        workflowSaveWarning = nil
        phase = .signedOut(message: nil)
    }

    /// 매핑 마법사에서 "시작하기"를 눌렀을 때. 매핑은 강제하지 않으므로
    /// 일부 상태가 비어 있어도 받아들이고, 남은 것을 배지로 알린다.
    public func confirmMapping(_ map: WorkflowMap) async {
        do {
            try workflow.save(map)
            workflowSaveWarning = nil
        } catch {
            // credentialSaveWarning과 같은 이유로 삼키지 않는다: 저장이 실패해도 사용자를
            // 마법사로 되돌리지 않고 .ready로 보내되(매핑은 강제하지 않는다는 원칙과 같은
            // 결), 다음 동기화가 전부 무동작(I1)이 되고 재실행하면 마법사가 다시 뜬다는
            // 사실을 화면이 보여줄 수 있게 남겨 둔다.
            workflowSaveWarning = "워크플로 매핑을 저장하지 못했습니다. 앱을 다시 시작하면 다시 설정해야 할 수 있습니다."
        }
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
        guard let client, let map = try? workflow.load() else {
            // 예전에는 여기서 조용히 return했다. `SyncScheduler.requestSync`는 던지지
            // 않는 `perform()`을 성공으로 취급해 `consecutiveFailures`를 지우고
            // `lastSyncAt`을 갱신한다(I1) — 그런데 이 분기는 요청을 아예 보내지 않았다.
            // 로그인 전(만료 직후 등)이거나 워크플로 매핑을 읽지 못한 상태에서 부른
            // 것이므로 성공이 아니다 — 던져서 스케줄러가 실패로 집계하게 한다.
            //
            // 실제 응답 실패(SyncFailure)와는 다른 타입으로 던진다: 이 상태는 축약할
            // 응답 본문이 없는 "아직 준비되지 않음"이다. `SyncFailure(redacting:)`으로
            // 감싸면 진단에서 둘을 구분할 수 없어진다.
            throw SyncNotConfigured()
        }

        let engine = SyncEngine(
            source: JiraIssueSource(client: client),
            store: store, rules: rules, workflow: map, calendar: calendar
        )
        // performSync() 시작 시점의 세대를 캡처한다. `SyncEngine.sync()`가 페치를 끝낸
        // 직후 이 값이 그때도 여전히 최신인지 확인한다 — 그 사이 로그아웃하거나 다른
        // 계정으로 로그인했다면 syncGeneration이 올라가 있으므로, 이미 날아간 페치
        // 결과를 새 계정의 스토어에 쓰지 않는다(I4).
        let generation = syncGeneration
        do {
            let outcome = try await engine.sync(
                jql: "assignee = currentUser() AND statusCategory != Done",
                now: clock(),
                isStillCurrent: { [weak self] in self?.syncGeneration == generation }
            )
            summary = outcome.summary
            if phase == .expired { phase = .ready }   // 재인증 없이 회복된 경우
        } catch JiraError.unauthorized {
            phase = .expired
            throw JiraError.unauthorized
        } catch is CancellationError {
            // 세대가 바뀌어 SyncEngine이 스스로 중단한 경우다. 사용자 잘못도 아니고
            // 실제 응답 실패도 아니므로 SyncFailure로 감싸 "연결하지 못했습니다" 같은
            // 무서운 문구로 노출하지 않는다 — 그대로 다시 던져 스케줄러가 실패로
            // 집계하되(요청이 완결되지 못한 건 사실이다), lastFailure 문자열은
            // "CancellationError()"로 남아 diagnostics에서 이 경로임을 알아볼 수 있다.
            throw CancellationError()
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
        let me: JiraUser
        do {
            me = try await candidate.myself()
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
        // 이 시점 이전에 시작된 동기화는 더 이상 유효하지 않다 — 이 사용자로(또는 이
        // 사용자가 다른 계정으로) 새로 인증됐으니, 그 전에 날아간 페치가 나중에 끝나도
        // 스토어에 쓰면 안 된다(I4).
        syncGeneration += 1

        // 스토어가 어느 계정을 담고 있는지 여기서 직접 기록한다. 자격증명 저장소로는
        // "계정이 바뀌었는가"를 판단할 수 없다 — signOut()이 바로 그 저장소를 지우기
        // 때문이다(v0.1 스펙 §8.2, AccountBindingStore.swift 참고). accountBinding은
        // signOut()이 지우지 않으므로, 로그아웃 후 종료했다가 다른 계정으로 재로그인하는
        // 경로(v0.1의 유일한 로그아웃 경로 — 만료 배너의 버튼)도 여기서 걸러진다. 이
        // 검사는 persistOnSuccess와 무관하게(즉 start()에서도) 실행돼야 한다 — 그래야
        // "로그아웃 → 종료 → 재실행 → 다른 계정 로그인"이 커버된다.
        //
        // `try?`로 읽는 이유는 자격증명 처리와 같다: 바인딩을 못 읽으면 "전환 아님"으로
        // 보수적으로 판단해 미러를 남긴다. 지우는 쪽이 되돌릴 수 없는 방향이기 때문이다.
        // 읽기 실패와 "아직 바인딩이 없음"(nil)은 다르게 다룬다. 읽지 못했다는 것은 저장소를
        // 신뢰할 수 없다는 뜻이므로 **쓰지도 않는다** — 미러는 보수적으로 남겨둔 채 바인딩만
        // 새 accountId로 덮으면, 다음 실행에서는 둘이 서로 다른 계정을 가리키는데 검사는
        // 통과한다. 그 순간 두 계정의 티켓과 이벤트가 한 스토어에 섞인다.
        do {
            let bound = try accountBinding.load()
            if let bound, bound != me.accountId {
                try? store.reset()
            }
            try? accountBinding.save(me.accountId)
        } catch {
            // 미러도 바인딩도 건드리지 않는다. 지우는 쪽도 덮는 쪽도 되돌릴 수 없다.
        }

        if persistOnSuccess {
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
        do {
            if try workflow.load() != nil {
                phase = .ready
                return
            }
        } catch {
            // 매핑이 **없는 것**과 매핑을 **읽지 못한 것**은 다르다. 둘을 합쳐 조용히
            // 마법사로 보내면, 이미 설정을 끝낸 사용자가 디스크 문제 한 번에 처음으로
            // 되돌아가고 화면 어디에도 이유가 없다. 보내는 곳은 같지만(매핑 없이는 모든
            // 점수가 0이다) 왜 다시 묻는지는 남긴다.
            workflowSaveWarning = "저장된 워크플로 매핑을 읽지 못했습니다. 다시 설정해 주세요."
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

/// `performSync()`가 로그인 전(client == nil)이거나 워크플로 매핑을 읽지 못한 상태에서
/// 불렸을 때 던진다. 응답 본문을 담지 않으므로 `SyncFailure`로 감쌀 필요가 없다 — 그냥
/// 던지는 것 자체가 목적이다(I1 참고: 예전에는 조용히 return해서 스케줄러가 이걸 성공으로
/// 오해했다).
private struct SyncNotConfigured: Error {}
