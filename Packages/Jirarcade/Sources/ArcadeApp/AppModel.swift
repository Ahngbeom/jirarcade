import Foundation
import ArcadeCore
import JiraKit

/// 앱 전체 상태를 소유한다. SwiftUI를 import하지 않으므로 화면 없이 테스트된다.
@Observable @MainActor
public final class AppModel {
    public private(set) var phase: Phase = .launching
    public private(set) var lastSync: SyncRunSummary?
    public private(set) var observationDays: Int = 0
    public private(set) var unmappedStatuses: [String] = []
    /// 로그인은 성공했지만 자격증명을 저장하지 못했을 때 세팅된다. `phase`는 `.ready`로 계속
    /// 진행한다 — 사용자는 이미 인증됐으니 되돌려보내지 않되, 다음 실행에서 다시 로그인해야
    /// 할 수 있다는 사실을 화면이 보여줄 수 있게 한다.
    /// 다시 연결할 때 사이트·이메일을 채워 넣기 위해 기억해 둔 값.
    /// 로그인 화면이 '첫 연결'과 '토큰만 갱신' 중 어느 모드로 뜰지도 이 값이 정한다.
    public private(set) var signInHint: SignInHint?

    /// 토큰 갱신이 거부됐을 때의 사유. `phase`를 건드리지 않는 이유는
    /// `ValidationFailureRouting.renewalSheet`에 적어 두었다.
    public private(set) var tokenRenewalMessage: String?

    public private(set) var credentialSaveWarning: String?
    /// 매핑은 성공했지만 저장하지 못했을 때 세팅된다. `credentialSaveWarning`과 같은 이유로
    /// 조용히 삼키지 않는다 — 그러지 않으면 모든 동기화가 영구히 무동작(I1)이 되는데
    /// 사용자는 그 사실을 알 방법이 없다.
    public private(set) var workflowSaveWarning: String?

    /// 백필 진행률. 실행 중일 때만 값이 있다.
    public struct BackfillProgress: Sendable, Equatable {
        public let processed: Int
        /// 총계를 모르면 nil이다. 새 검색 API는 total을 주지 않으므로
        /// 처리한 수를 총계로 삼으면 진행률이 늘 100%로 보인다.
        public let total: Int?
    }
    public private(set) var backfillProgress: BackfillProgress?
    /// 백필 실행 태스크가 살아 있는가. **"실행 중"의 판정은 이 값이고 `backfillProgress`가
    /// 아니다** — 진행률은 첫 페이지를 다 처리한 뒤에야 채워지는데, 그 전에 총계 조회 1회 +
    /// 카탈로그 조회 1회 + 첫 페이지 조회 + 티켓별 보충 조회가 일어나고 실측에서 이 구간이
    /// 수십 초였다. 그동안 화면이 "과거 기록 불러오기"를 활성 상태로 두면 사용자에게는
    /// 버튼이 먹지 않은 것처럼 보인다.
    public private(set) var isBackfilling: Bool = false
    /// 전체 이력 기준 요약. 통산 XP를 계산하는 자리는 여기 하나뿐이다 —
    /// 동기화 경로와 집계 경로가 각자 계산하면 갱신 시점이 달라, 백필 직후부터 다음
    /// 동기화까지 한 화면에 "LV.1"과 "통산 LV.50"이 나란히 뜬다.
    public private(set) var lifetimeSummary: PlayerSummary?
    /// 최근 `RuleSet.seasonDays`일 기준 요약. HUD의 XP 바가 이 값을 쓴다.
    public private(set) var seasonSummary: PlayerSummary?
    /// 중단된 백필이 남아 있는지. 설정 화면이 "이어서 불러오기"를 보여줄 근거다.
    public private(set) var hasResumableBackfill: Bool = false
    /// 지난 백필이 실패로 멈춘 사유. 성공했거나 사용자가 중단했으면 nil이다.
    /// 취소는 실패가 아니다 — 스스로 누른 것을 "실패했습니다"로 보여주면 안 된다.
    /// (엔진이 취소를 기록하지 않으므로 자연히 nil이 된다.)
    ///
    /// 담기는 값은 에러 **타입 이름**뿐이다(호스트·JQL·토큰 조각이 새지 않게) —
    /// 화면은 그대로 보여주지 말고 문장으로 감싸야 한다.
    public private(set) var lastBackfillFailure: String?
    /// 마지막 백필이 상태 카탈로그를 못 받아 폴백 ②가 비활성인 채로 돌았다.
    /// 매핑에 없는 과거 상태가 전부 0점 처리됐다는 뜻이라 사용자에게 알려야 한다.
    ///
    /// 스토어가 원본이다(`BackfillRun.catalogUnavailable`). 메모리에만 두고 성공 경로에서만
    /// 대입하면, 카탈로그를 못 받은 채 **실패로 끝난 실행**·앱 재시작·이어받기 성공에서
    /// 경고가 사라진다 — 하필 degradation이 가장 잘 일어나는 조건들이다.
    public private(set) var backfillWasDegraded: Bool = false
    /// 백필이 과거 이력에서 발견한, 현재 매핑에 없는 상태명.
    /// 매핑 마법사가 이 목록을 후보에 더해 보여준다 — 폴백이 추정한 단계를 사용자가
    /// 바로잡으면 재집계에서 사용자 매핑이 폴백을 이겨 소급 XP가 정확해진다.
    public private(set) var historyDiscoveredStatuses: [String] = []
    /// 로그인한 계정. "내가 직접 옮긴 것만 XP" 판정에 쓴다.
    public private(set) var myAccountId: String?
    /// 현재 미러를 키 오름차순으로. 보드가 읽는다.
    ///
    /// 정렬을 여기서 하는 이유: 미러는 딕셔너리라 순회 순서가 불안정하고, 보드가 매
    /// 렌더마다 정렬하면 같은 일을 반복한다. 갱신은 동기화마다 한 번뿐이다.
    public private(set) var issues: [ObservedIssue] = []
    /// 티켓별 현재 상태 진입 시각. 없는 티켓은 보드가 `jiraUpdatedAt`으로 폴백하고
    /// 그 사실을 화면에 표시한다.
    public private(set) var statusEnteredAt: [String: Date] = [:]
    /// 위생 리포트. HUD가 읽는다.
    public private(set) var hygiene: HygieneReport?
    /// 실효 워크플로 맵(사용자 매핑 + 폴백)의 **캐시**.
    ///
    /// `currentMapping`/`currentFallbacks`처럼 매 접근마다 디스크를 치면 안 된다 —
    /// 보드는 렌더마다 이 값을 읽고 티켓 수만큼 `stage(for:)`를 부른다.
    public private(set) var boardWorkflow = WorkflowMap(statusToStage: [:])
    /// 정규화된 Jira 호스트. 티켓 링크를 만들 때만 쓴다.
    /// 자격증명 전체가 아니라 호스트 하나만 내보낸다 — 이메일과 토큰은 화면에 닿을 이유가 없다.
    public private(set) var siteHost: String?
    /// 실행 취소 창에서 대기 중인 전이. 티켓 키로 색인한다.
    ///
    /// 하나만 대기하게 하면 "새 전이가 오면 앞의 것을 즉시 확정한다"는 규칙이 따라붙고,
    /// 그러면 세 티켓을 연달아 정리하는 흐름에서 앞의 두 건이 취소 기회를 잃는다.
    /// 5초 실행 취소가 "다른 티켓을 건드리지 않는 한"이라는 숨은 조건을 갖게 된다.
    public private(set) var pendingTransitions: [String: PendingTransition] = [:]
    /// 티켓별 마지막 전이 실패 안내. **Jira가 준 사유를 담지 않는다** — 앱이 쓴 문구만 담는다.
    public private(set) var transitionFailures: [String: String] = [:]
    /// 상세 시트가 지금 보여줄 상태. 시트가 열려 있을 때만 `.idle`이 아니다 —
    /// 미러에는 들어가지 않는 순전히 화면용 값이다(`IssueDetail.swift` 참고).
    public private(set) var detailState: IssueDetailState = .idle
    /// 상세 시트를 채우는 중인 요청. `closeDetail()`과 `signOut()`이 이걸 취소해,
    /// 시트가 닫히거나 로그아웃한 뒤에도 Jira에 요청이 계속 나가지 않게 한다.
    private var detailTask: Task<Void, Never>?
    /// `openDetail`을 부를 때마다 하나씩 올라간다. 늦게 도착한 응답이 지금 시트가
    /// 실제로 기다리는 요청인지 가린다. `syncGeneration`만으로는 부족하다 — 그건
    /// "계정이 바뀌었는가"만 답하므로, 같은 계정에서 A를 닫고 B를 연 경우(둘 다
    /// syncGeneration은 그대로다)까지는 잡지 못한다.
    private var detailToken = 0

    /// 저장이 날아가 있는 티켓. 버튼을 잠가 이중 제출을 막는다 — 댓글 POST는
    /// 멱등이 아니라 두 번 누르면 댓글이 둘이 된다.
    public private(set) var editInFlight: Set<String> = []
    /// 화면에 그릴 실패 문구. **Jira가 준 사유가 들어 있지 않다.**
    public private(set) var editFailures: [String: String] = [:]
    private var editTasks: [String: Task<Void, Never>] = [:]

    var editTaskCountForTesting: Int { editTasks.count }

    /// 대기 중인 타이머. 취소하려면 이걸 취소한다.
    private var transitionTasks: [String: Task<Void, Never>] = [:]
    private let transitionSleep: @Sendable (Duration) async throws -> Void

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
    private let sprintField: any SprintFieldStore
    private let signInHintStore: any SignInHintStore
    private let clientFactory: (any AuthProvider) -> JiraClient
    /// 백필이 쓸 changelog 소스를 만든다. `clientFactory`와 같은 패턴이다 —
    /// 프로덕션은 기본값으로 실제 구현을 쓰고, 테스트만 갈아 끼운다.
    private let changelogSourceFactory: (JiraClient) -> any ChangelogSource
    private let clock: () -> Date
    private let calendar: Calendar
    private var scheduler: SyncScheduler?
    private let rules: RuleSet
    private let settings: AppSettings

    /// 로그인 후에만 존재한다. 매핑 조회와 동기화에 쓴다.
    private var client: JiraClient?

    /// 실행 중인 백필. 중단하려면 이걸 취소한다.
    private var backfillTask: Task<Void, Never>?

    /// 스케줄러의 실패 집계. UI가 "연결하지 못했습니다"를 언제 보여줄지 판단한다.
    public var schedulerState: SyncScheduler.State { scheduler?.state ?? .init() }

    /// 주기 동기화 루프가 도는 중인가. 백필이 동기화를 멈췄다가 **원래 돌고 있었을 때만**
    /// 되살린다는 규칙을 바깥에서 확인할 수 있는 유일한 창이다.
    public var isSyncScheduled: Bool { scheduler?.isRunning ?? false }

    public init(
        store: ArcadeStore,
        credentials: any CredentialStore,
        workflow: any WorkflowStore,
        accountBinding: any AccountBindingStore,
        sprintField: any SprintFieldStore,
        signInHint: any SignInHintStore = UserDefaultsSignInHintStore(),
        clientFactory: @escaping (any AuthProvider) -> JiraClient,
        clock: @escaping () -> Date,
        calendar: Calendar,
        rules: RuleSet = .default,
        settings: AppSettings = .default,
        changelogSourceFactory: ((JiraClient) -> any ChangelogSource)? = nil,
        transitionSleep: @Sendable @escaping (Duration) async throws -> Void
            = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.credentials = credentials
        self.workflow = workflow
        self.accountBinding = accountBinding
        self.sprintField = sprintField
        self.signInHintStore = signInHint
        self.clientFactory = clientFactory
        self.changelogSourceFactory =
            changelogSourceFactory ?? { JiraChangelogSource(client: $0) }
        self.clock = clock
        self.calendar = calendar
        self.rules = rules
        self.settings = settings
        self.transitionSleep = transitionSleep
        if let raw = UserDefaults.standard.string(forKey: "appearance"),
           let saved = AppearancePreference(rawValue: raw) {
            self.appearancePreference = saved
        }
        // 힌트는 `start()`보다 먼저 필요하다 — 자격증명이 아예 없는 첫 화면이
        // '토큰만 갱신' 모드로 떠야 하는지를 로그인 화면이 이 값으로 판단한다.
        // 읽지 못하면 nil, 즉 '첫 연결' 모드다.
        self.signInHint = (try? signInHint.load()).flatMap(SignInHint.init(rawValue:))
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
        // 검증 **전에** 채운다. 이 기능이 생기기 전부터 쓰던 사용자는 힌트 저장소가
        // 비어 있고 Keychain에만 값이 있는데, 그 사용자가 맞이하는 첫 화면이 바로
        // 만료 배너다 — 검증 성공을 기다리면 정작 갱신이 필요한 순간에 힌트가 없다.
        rememberSignInHint(site: saved.site, email: saved.email)
        await validate(saved, persistOnSuccess: false, failureRouting: .expiredBanner)
    }

    /// 로그인 화면에서 호출한다.
    public func signIn(site: String, email: String, token: String) async {
        phase = .validating
        credentialSaveWarning = nil
        await validate(Credentials(site: site, email: email, token: token),
                       persistOnSuccess: true, failureRouting: .signInScreen)
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
        // 대기 중인 전이 타이머도 로그아웃의 대상이다. 취소하지 않으면 이 타이머는
        // syncGeneration을 보지 않는 유일한 비동기 경로라서 계속 잠들어 있다가, 다음
        // 계정으로 로그인한 뒤 창이 지나는 순간 그 계정의 client로 옛 전이를
        // POST해버린다(최종 전체 브랜치 리뷰 Finding 1). `pendingTransitions`·
        // `transitionFailures`도 함께 비운다 — 지우지 않으면 다음 세션에서 같은 키의
        // 티켓이 나타날 때(예: 같은 사이트로 재로그인) 남의 대기 배너·실패 안내가 그
        // 티켓 위에 겹쳐 그려진다.
        transitionTasks.values.forEach { $0.cancel() }
        transitionTasks = [:]
        pendingTransitions = [:]
        transitionFailures = [:]
        // 진행 중인 저장도 로그아웃의 대상이다. 남겨두면 다음 계정으로 로그인한 뒤
        // 완료 핸들러가 그 계정의 화면에 실패를 그리거나 동기화를 유발한다.
        // 전이 타이머와 같은 이유이며, 같은 사고가 실제로 출하된 적이 있다.
        editTasks.values.forEach { $0.cancel() }
        editTasks = [:]
        editInFlight = []
        editFailures = [:]
        // 상세 시트가 열려 있던 채로 로그아웃하면, 남겨둔 페치가 옛 계정의 client로
        // 댓글 요청까지 마저 보낸다(최종 전체 브랜치 리뷰 Finding 1) — 취소해 끊는다.
        detailTask?.cancel()
        detailTask = nil
        detailToken += 1
        detailState = .idle
        // 세대를 올려 진행 중이던 페치가 끝나도 이 계정의 스토어에 쓰지 못하게 막는다
        // (I4). 계정 바인딩(`accountBinding`)은 여기서 지우지 않는다 — 지우면 다음 로그인이 "계정이
        // 바뀌었는지" 판단할 근거를 잃는다. validate() 참고.
        syncGeneration += 1
        try? credentials.clear()
        client = nil
        // 집계값도 함께 버린다 — 이 계정의 이벤트에서 나온 숫자이므로, 남겨두면
        // 다음 로그인이 끝나기 전까지 남의 XP·레벨이 화면에 떠 있다.
        lifetimeSummary = nil
        seasonSummary = nil
        myAccountId = nil
        siteHost = nil
        // 다른 테넌트에는 그 필드가 없다. 남겨두면 존재하지 않는 필드를 계속 요청한다.
        try? sprintField.clear()
        // 보드 상태도 이 계정의 미러에서 나온 값이다. 남겨두면 다음 로그인이 끝나기
        // 전까지 남의 티켓이 화면에 떠 있다.
        issues = []
        statusEnteredAt = [:]
        hygiene = nil
        boardWorkflow = WorkflowMap(statusToStage: [:])
        // 백필에서 나온 값들도 함께 버린다. 남으면 다른 계정으로 로그인했을 때 이전 조직의
        // 상태명이 새 계정의 매핑 후보로 뜨고(조직이 다르면 완전히 무의미한 목록이다),
        // 이전 계정의 중단 사유와 정확도 경고가 새 계정의 설정 화면에 붙는다.
        // `ArcadeStore.reset()`이 `BackfillRun`을 지우는 것과 같은 이유다.
        historyDiscoveredStatuses = []
        lastBackfillFailure = nil
        backfillWasDegraded = false
        // 재개 제안도 이 계정의 미완료 run에서 나온 값이다. 바로 위 세 줄과 같은 이유로
        // 지운다 — 계정을 바꾸면 validate()가 미러와 함께 run도 버리므로(store.reset()),
        // 남겨두면 다음 로그인이 끝나기 전까지 모델만 이전 계정의 진행 상황을 들고 있다.
        hasResumableBackfill = false
        lastSync = nil
        credentialSaveWarning = nil
        workflowSaveWarning = nil
        // 갱신 시트의 실패 문구도 이 계정의 것이다. `signInHint`는 **지우지 않는다** —
        // 로그아웃은 "Jira와 더 이상 말하지 않는다"이지 "나를 잊어라"가 아니다.
        // 잊는 것은 `forgetAccount()` 하나뿐이다.
        tokenRenewalMessage = nil
        phase = .signedOut(message: nil)
    }

    /// 사이트·이메일은 기억한 것을 그대로 쓰고 **토큰만** 새것으로 바꾼다.
    ///
    /// 만료 배너의 갱신 시트와 로그인 화면의 '토큰 갱신' 모드가 함께 부른다.
    /// 실패해도 `phase`를 건드리지 않으므로(`ValidationFailureRouting.renewalSheet`)
    /// 사용자가 보고 있던 미러가 그대로 남는다.
    ///
    /// - Returns: 갱신에 성공했는가. 실패 사유는 `tokenRenewalMessage`에 담긴다.
    @discardableResult
    public func renewToken(_ token: String) async -> Bool {
        tokenRenewalMessage = nil
        guard let hint = signInHint else {
            tokenRenewalMessage =
                "기억된 연결 정보가 없습니다. 로그아웃한 뒤 사이트 주소와 이메일부터 입력해 주세요."
            return false
        }
        // `Credentials.init`이 앞뒤 공백을 떼므로 공백만 붙여넣은 경우도 여기서 걸린다.
        // 서버에 물어볼 것이 없는 입력으로 요청을 보내지 않는다.
        let creds = Credentials(site: hint.site, email: hint.email, token: token)
        guard !creds.token.isEmpty else {
            tokenRenewalMessage = "새 API 토큰을 입력해 주세요."
            return false
        }

        guard await validate(creds, persistOnSuccess: true, failureRouting: .renewalSheet)
        else { return false }

        // 동기화 루프를 여기서 직접 건다. `RootView`는 `.expired → .ready` 전이에서
        // 루프를 걸지 않는데(`performSync()`가 재인증 없이 스스로 회복한 경우 타이머를
        // 두 번 만들지 않기 위한 가드다), 시작 시점에 만료였다면 루프는 **한 번도**
        // 돈 적이 없다. 그 경우 갱신에 성공하고도 영영 동기화되지 않는다.
        //
        // 이미 돌고 있던 루프를 다시 거는 것도 여기서는 옳다 — 방금 인증 문제가
        // 해소됐으므로 쌓인 백오프를 리셋하고 즉시 한 번 받아오는 것이 사용자가
        // 기대하는 동작이다.
        if phase == .ready {
            startSyncing()
            await syncNow(reason: .manual)
        }
        return true
    }

    /// 로그아웃하고 기억한 사이트·이메일까지 버린다. 로그인 화면의
    /// "다른 계정으로 연결"이 부르는 유일한 경로다.
    public func forgetAccount() async {
        await signOut()
        signInHint = nil
        try? signInHintStore.clear()
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
        // 매핑은 채점의 **입력**이다. 다시 계산하지 않으면 사용자가 잘못된 폴백을 고쳐도
        // XP·레벨이 그대로여서 아무 일도 일어나지 않은 것처럼 보인다. 동기화 완료를
        // 기다리지 않고 저장된 이벤트로 바로 도는 이유가 그것이다 — 즉시 반영돼야 한다.
        await recomputeFromLog()
        phase = .ready
    }

    /// 백필이 statusCategory로 추정해 저장한 폴백. 마법사가 행마다 "지금은 이 단계로
    /// 채점 중"을 보여줄 근거다.
    ///
    /// **초기 선택으로 채우면 안 된다.** 그러면 사용자가 확인만 눌러도 추정값 전부가
    /// 사용자 매핑으로 승격되고, 그 뒤로는 폴백 갱신이 영영 이기지 못한다
    /// (`effectiveWorkflow()`에서 사용자 매핑이 항상 위에 얹히기 때문이다).
    ///
    /// 읽기 실패를 빈 맵으로 접는 것은 `currentMapping`과 같은 이유다 — 추정값이므로
    /// 못 읽었다고 화면을 막을 일이 아니고, 표시가 빠질 뿐이다.
    public var currentFallbacks: WorkflowMap {
        (try? workflow.loadFallbacks()) ?? WorkflowMap(statusToStage: [:])
    }

    /// **지금 이 순간** 추정값으로 채점되고 있는 상태. 설정 화면의 경고가 이 값을 센다.
    ///
    /// `historyDiscoveredStatuses.count`를 쓰면 두 가지로 거짓이 된다.
    /// ① 그 목록은 백필 시점의 스냅샷이라 사용자가 12개를 전부 지정해도 줄지 않는다.
    /// ② 폴백이 닿지 않은 상태(카탈로그를 못 받은 run에서는 전부 여기 해당한다)까지
    ///    섞여서, "상태 목록을 불러오지 못했습니다"(=전부 0점)와 "N개가 추정값으로
    ///    채점되고 있습니다"가 같은 화면에 나란히 뜬다.
    ///
    /// 저장된 폴백에 있으면서 사용자 매핑에도 제외 목록에도 없는 것만 센다 —
    /// 그것이 실제로 추정이 적용되는 집합이다(`effectiveWorkflow()`와 같은 규칙).
    public var guessScoredStatuses: [String] {
        let mapping = currentMapping
        return currentFallbacks.statusToStage.keys
            .filter { mapping.statusToStage[$0] == nil && !mapping.excludedStatuses.contains($0) }
            .sorted()
    }

    /// 저장된 워크플로 매핑. 마법사를 다시 열 때 초기값으로 쓴다 —
    /// 빈 화면으로 시작하면 확정하는 순간 이미 설정한 매핑이 통째로 사라진다.
    ///
    /// 읽기 실패와 "아직 없음"을 구분하지 않고 빈 맵으로 접는다: 둘 다 마법사가
    /// 처음부터 고르게 하는 것 말고 할 수 있는 일이 없고, 읽지 못한 사실 자체는
    /// `routeAfterAuthentication()`이 이미 `workflowSaveWarning`으로 알린다.
    public var currentMapping: WorkflowMap {
        (try? workflow.load()) ?? WorkflowMap(statusToStage: [:])
    }

    /// 설정에서 매핑 마법사를 다시 연다.
    ///
    /// 첫 설정 이후에는 `routeAfterAuthentication()`이 마법사로 보내지 않으므로,
    /// 이 경로가 없으면 백필이 발견한 과거 상태를 사용자가 영영 고칠 수 없다.
    /// 폴백은 statusCategory에서 끌어낸 추정이라 방향까지 틀릴 수 있다 —
    /// 보류 성격의 상태가 `done` 범주에 있으면 완료 전이로 채점되고 마감 보너스까지 받는다.
    ///
    /// `mappingCandidates()`가 실패하면 빈 배열을 준다. 그래도 마법사는 열려야 한다 —
    /// 고칠 것은 지금 티켓의 상태가 아니라 `historyDiscoveredStatuses`이고,
    /// 마법사가 그 목록을 후보에 더해 보여준다.
    public func reopenMapping() async {
        phase = .mappingWorkflow(candidates: await mappingCandidates())
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
        // `try?`가 Optional을 평탄화하므로(SE-0230) 존재 확인은 한 번이면 된다.
        // 값을 꺼내 쓰지 않고 **있는지만** 보는 이유: 채점에 넘기는 것은 폴백을 밑에 깐
        // `effectiveWorkflow()`이지만, "아직 매핑을 안 했다/못 읽었다"는 판정은 여전히
        // 사용자 매핑만으로 해야 한다. 폴백은 백필이 추정한 값이라 그것만으로 설정을
        // 끝낸 것으로 볼 수 없다.
        guard let client, (try? workflow.load()) != nil else {
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
            source: JiraIssueSource(client: client,
                                    sprintFieldID: try? sprintField.load()),
            store: store, rules: rules, workflow: effectiveWorkflow(), calendar: calendar,
            // 여기까지 왔다면 validate()가 이미 accountId를 채웠다. 넘기지 않으면 이
            // 경로만 실행자 필터를 건너뛰어, 같은 이벤트가 summary와 lifetimeSummary에서
            // 다른 XP를 받는다. 매 호출마다 새로 읽으므로 계정 전환 후에도 옛 값이 남지 않는다.
            myAccountId: myAccountId
        )
        // performSync() 시작 시점의 세대를 캡처한다. `SyncEngine.sync()`가 페치를 끝낸
        // 직후 이 값이 그때도 여전히 최신인지 확인한다 — 그 사이 로그아웃하거나 다른
        // 계정으로 로그인했다면 syncGeneration이 올라가 있으므로, 이미 날아간 페치
        // 결과를 새 계정의 스토어에 쓰지 않는다(I4).
        let generation = syncGeneration
        do {
            // 반환된 요약은 쓰지 않는다. 통산 XP를 만드는 자리는 `recomputeFromLog()`
            // 하나뿐이어야 한다 — 여기서도 따로 담아 두면 갱신 시점이 갈려, 백필 직후부터
            // 다음 동기화까지 캐비닛과 HUD가 서로 다른 레벨을 나란히 보여준다.
            _ = try await engine.sync(
                jql: "assignee = currentUser() AND statusCategory != Done",
                now: clock(),
                isStillCurrent: { [weak self] in self?.syncGeneration == generation }
            )
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
        // 방금 들어온 이벤트를 곧바로 집계에 반영한다. 여기서 갱신하지 않으면 화면의
        // 레벨은 다음 인증이나 백필 종료까지 옛 값에 머문다.
        await recomputeFromLog()
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

    // MARK: - 보드

    /// 보드가 그릴 좌표. 뷰가 시계와 달력을 직접 만들지 않도록 모델이 만든다.
    ///
    /// 매 렌더마다 불린다. `BoardLayout.snapshot`은 순수 함수이고 티켓 수만큼만 도는
    /// 계산이라 미러 규모(수십~수백 건)에서는 문제가 없다 — 스토어를 치지 않는 것이
    /// 중요하고, 그래서 `issues`·`statusEnteredAt`·`boardWorkflow`를 미리 갖고 있는다.
    ///
    /// - Parameter minimumSpacing: 뷰가 카드 폭과 창 폭으로 계산해 넘긴다.
    public func boardSnapshot(minimumSpacing: Double) -> BoardSnapshot {
        BoardLayout.snapshot(
            issues: optimisticIssues,
            statusEnteredAt: statusEnteredAt,
            statusRevisits: [:],
            workflow: boardWorkflow,
            rules: rules,
            minimumSpacing: minimumSpacing,
            now: clock(),
            calendar: calendar
        )
    }

    /// 대기 중인 전이를 미러 위에 **겹친** 목록.
    ///
    /// 스토어를 건드리지 않는 것이 핵심이다 — 롤백은 `pendingTransitions`에서 지우는
    /// 것이고, Jira에는 아직 아무것도 보내지 않았으므로 되돌릴 것도 없다.
    private var optimisticIssues: [ObservedIssue] {
        guard !pendingTransitions.isEmpty else { return issues }
        return issues.map { issue in
            guard let pending = pendingTransitions[issue.key] else { return issue }
            // `ObservedIssue`는 전부 `let`이라 상태명만 바꾼 사본을 만든다.
            // `jiraUpdatedAt`은 **건드리지 않는다** — 아직 Jira에서 아무 일도 일어나지
            // 않았고, 여기서 지금 시각으로 밀면 정체일이 0으로 보였다가 실패 시
            // 되돌아오는 깜빡임이 생긴다.
            return ObservedIssue(
                key: issue.key, summary: issue.summary,
                statusName: pending.toStatusName, issueType: issue.issueType,
                priority: issue.priority, assigneeAccountId: issue.assigneeAccountId,
                assigneeName: issue.assigneeName, dueDate: issue.dueDate,
                jiraUpdatedAt: issue.jiraUpdatedAt
            )
        }
    }

    /// WIP 한도. 보드의 `active` 레인 헤더가 읽는다.
    /// 뷰가 `RuleSet.default`를 직접 보면 사용자가 규칙을 고쳐도 화면이 따라가지 않는다.
    public var wipLimit: Int { rules.wipLimit }

    // MARK: - 백필

    /// 과거 기록을 불러온다. 사용자가 설정에서 눌러 시작한다 — 자동 실행하지 않는다.
    public func startBackfill() async {
        await launchBackfill(resume: false)
    }

    /// 중단된 백필이 있으면 이어서 진행한다. 없으면 아무 일도 하지 않는다 —
    /// 요청조차 나가지 않아야 한다.
    public func resumeBackfillIfAvailable() async {
        guard (try? store.resumableBackfill()) != nil else { return }
        await launchBackfill(resume: true)
    }

    /// 실행 중인 백필을 중단한다. 이미 넣은 이벤트는 그대로 유효하고, 중단 지점의
    /// `nextPageToken`이 저장돼 있어 나중에 "이어서 불러오기"로 재개된다.
    public func cancelBackfill() {
        backfillTask?.cancel()
    }

    private func launchBackfill(resume: Bool) async {
        // 이미 돌고 있으면 두 번 시작하지 않는다 — 같은 페이지를 두 곳에서 훑으면
        // 진행률이 뒤엉킨다(이벤트 중복은 historyId가 막지만 카운터는 못 막는다).
        guard backfillTask == nil else { return }
        // 백필이 도는 동안에는 라이브 동기화를 멈춘다. 백필이 changelog를 받은 뒤 이벤트를
        // 넣기까지의 창(티켓별 보충 조회가 그 사이에 있다)에 동기화가 같은 티켓의 **새**
        // 전이를 기록하면, 그 전이는 방금 받은 changelog에 없으면서 백필의 대체 로직에
        // 지워진다. 다음 백필이 복원하지만 그 사이 점수가 튄다. 애초에 같은 데이터를 두
        // 경로로 받을 이유가 없다.
        //
        // 되살리는 것은 **원래 돌고 있었을 때만**이다. 무조건 켜면 아직 동기화를 시작하지
        // 않은 화면(설정에서 바로 백필을 누른 경우)에서 백필이 동기화를 시작시킨다.
        let wasSyncing = scheduler?.isRunning ?? false
        stopSyncing()
        defer { if wasSyncing { startSyncing() } }
        let task = Task { await runBackfill(resume: resume) }
        backfillTask = task
        // 첫 await 이전에 세운다 — 버튼을 누른 순간 화면이 반응해야 한다.
        isBackfilling = true
        await task.value
        backfillTask = nil
        isBackfilling = false
    }

    private func runBackfill(resume: Bool) async {
        guard let client else { return }
        // 동기화(`performSync`)와 달리 statusCategory로 좁히지 않는다 — 이미 Done인
        // 티켓의 과거 전이야말로 소급해야 할 것들이다.
        let jql = "assignee = currentUser()"

        // 진행 상태 저장(begin/advance/finish)은 엔진이 직접 한다 — 페이지 경계마다
        // 저장해야 하는데 여기서는 루프 안을 볼 수 없다. 여기서 또 부르면 이중 기록이 된다.
        let engine = BackfillEngine(
            source: changelogSourceFactory(client),
            store: store,
            workflow: effectiveWorkflow()
        )

        do {
            let outcome = try await engine.run(
                jql: jql, now: clock(), resume: resume
            ) { [weak self] processed, total in
                self?.backfillProgress = BackfillProgress(processed: processed, total: total)
            }
            persistFallbacks(outcome.resolvedFallbacks)
            // 정확도 경고는 여기서 대입하지 않는다 — 엔진이 run 행에 적어 두었고
            // `refreshDerivedState()`가 스토어에서 읽는다. 성공 경로에서만 대입하던 예전
            // 방식은 실패로 끝난 실행의 사실을 통째로 잃었다.
        } catch {
            // 실패·중단해도 여기까지 넣은 이벤트는 유효하고 진행 지점이 저장돼 있다.
            // run을 미완료로 남겨 "이어서 불러오기"가 뜨게 하는 것이 의도된 동작이다.
        }

        backfillProgress = nil
        await refreshDerivedState()
    }

    /// 새로 해석한 폴백을 기존 것과 **병합해** 저장한다. 덮어쓰면 이전 실행이
    /// 해석한 매핑이 사라진다 — 범위를 좁혀 다시 돌리면 폴백이 줄어드는 셈이다.
    private func persistFallbacks(_ discovered: [String: Stage]) {
        guard !discovered.isEmpty else { return }
        var merged = (try? workflow.loadFallbacks())?.statusToStage ?? [:]
        for (name, stage) in discovered { merged[name] = stage }
        try? workflow.saveFallbacks(WorkflowMap(statusToStage: merged))
    }

    /// 사용자 매핑에 백필이 추정한 폴백을 밑에 깔아 만든 채점용 맵.
    ///
    /// 동기화 경로와 백필 경로가 **같은 맵**을 써야 한다 — 다르면 같은 이벤트가
    /// 어느 경로로 집계됐는지에 따라 다른 XP를 받는다.
    ///
    /// 폴백 로드가 실패하면 빈 폴백으로 진행한다. 추정값이므로 앱을 막을 이유가 없다
    /// (사용자 매핑의 로드 실패는 지금처럼 별도로 다룬다).
    private func effectiveWorkflow() -> WorkflowMap {
        let base = (try? workflow.load()) ?? WorkflowMap(statusToStage: [:])
        let fallbacks = (try? workflow.loadFallbacks())?.statusToStage ?? [:]
        return base.merging(fallbacks)
    }

    /// 스토어에서 파생되는 상태를 한꺼번에 다시 읽는다. 로그인 직후와 백필 종료 후에
    /// 부른다 — 두 시점 모두 이벤트 로그와 미완료 run이 바뀌어 있을 수 있다.
    private func refreshDerivedState() async {
        hasResumableBackfill = (try? store.resumableBackfill()) != nil
        // 실패 사유는 스토어가 원본이다 — 앱을 다시 켜도 남아야 "이어서 불러오기"가
        // 왜 떠 있는지 설명할 수 있다. 읽지 못하면 nil, 즉 "알리지 않음"으로 둔다.
        lastBackfillFailure = try? store.lastBackfillFailure()
        // 정확도 경고도 스토어가 원본이다. 읽지 못하면 "알리지 않음"(false)으로 둔다 —
        // 읽기 실패를 경고로 바꾸면 멀쩡한 백필에 정확도 문제가 있다고 말하게 된다.
        backfillWasDegraded = (try? store.lastBackfillWasDegraded()) ?? false
        // 발견 목록도 스토어가 원본이다. `BackfillOutcome`에서 받으면 안 되는 이유가 둘 있다:
        // 재개한 실행의 outcome에는 **이번 실행분만** 담기지만 스토어는 run 전체를 누적하고,
        // 실패로 끝난 실행에는 outcome 자체가 없다(중단 지점까지의 발견은 스토어에 남아 있다).
        historyDiscoveredStatuses = (try? store.discoveredStatuses()) ?? []
        await recomputeFromLog()
    }

    /// 이벤트 로그와 미러에서 파생되는 모든 것을 다시 만든다 — 보드가 읽는 상태와
    /// 통산·시즌 요약.
    ///
    /// 동기화 성공과 로그인·백필 종료가 **공통으로 지나는 유일한 지점**이고, 이미
    /// 이벤트 로그와 미러를 둘 다 읽고 있다. 보드 갱신을 위해 새 갱신 시점이나 새
    /// 스토어 읽기를 만들 이유가 없다.
    private func recomputeFromLog() async {
        guard let events = try? store.loadEvents(),
              let mirror = try? store.loadMirror() else { return }
        let now = clock()
        // 한 번만 읽어 캐시한다. 예전에는 이 함수 안에서만 두 번 불렀고 화면이 렌더마다
        // 또 불렀다(후속 항목 §4.2).
        let workflowMap = effectiveWorkflow()
        boardWorkflow = workflowMap

        issues = mirror.values.sorted { $0.key < $1.key }
        statusEnteredAt = StatusTimeline.latestStatusEntry(
            from: events, revertWindowMinutes: rules.revertWindowMinutes
        )
        hygiene = HygieneCalculator(rules: rules, workflow: workflowMap, calendar: calendar)
            .evaluate(issues, now: now)

        let engine = ScoreEngine(
            rules: rules, workflow: workflowMap,
            calendar: calendar, myAccountId: myAccountId
        )
        lifetimeSummary = engine.recompute(events: events, issues: mirror, now: now).summary
        let seasonStart = now.addingTimeInterval(-Double(rules.seasonDays) * 86_400)
        seasonSummary = engine.recompute(events: events, issues: mirror, now: now,
                                         since: seasonStart).summary
    }

    // MARK: - 내부

    /// 검증이 실패했을 때 그 사실을 **어디에** 내놓을 것인가.
    ///
    /// 예전에는 `persistOnSuccess`가 이 판단까지 겸했다(참이면 로그인 화면, 거짓이면
    /// 만료 배너). 토큰 갱신은 그 두 조합 어디에도 들어가지 않는다 — 저장은 하지만
    /// phase는 건드리면 안 된다. `.expired`는 미러를 보여주는 단계라(`Phase.showsMirror`)
    /// 실패를 로그인 화면으로 옮기면 사용자가 보고 있던 보드가 통째로 사라진다.
    private enum ValidationFailureRouting {
        /// 로그인 화면으로 보내고 사유를 폼에 띄운다.
        case signInScreen
        /// 만료 배너를 띄운 채 미러를 계속 보여준다.
        case expiredBanner
        /// phase를 그대로 두고 사유만 `tokenRenewalMessage`에 담는다.
        case renewalSheet
    }

    /// 검증 실패를 라우팅이 정한 자리에 내려놓는다.
    private func reportValidationFailure(
        _ message: String, routing: ValidationFailureRouting
    ) {
        switch routing {
        case .signInScreen:  phase = .signedOut(message: message)
        case .expiredBanner: phase = .expired
        case .renewalSheet:  tokenRenewalMessage = message
        }
    }

    @discardableResult
    private func validate(
        _ creds: Credentials,
        persistOnSuccess: Bool,
        failureRouting: ValidationFailureRouting
    ) async -> Bool {
        let auth: APITokenAuth
        do {
            auth = try APITokenAuth(site: creds.site, email: creds.email, token: creds.token)
        } catch {
            reportValidationFailure("사이트 주소를 확인해 주세요.", routing: failureRouting)
            return false
        }

        var candidate = clientFactory(auth)
        let me: JiraUser
        do {
            me = try await candidate.myself()
        } catch JiraError.unauthorized {
            // 401이 자격증명 오류라는 뜻이 **아닐 수 있다.** Atlassian의 스코프 있는 API
            // 토큰은 사이트 직접 경로(`{site}.atlassian.net/rest/api/3`)를 거부한다 —
            // 엣지가 인증 단계에 도달하기도 전에 401과 HTML 차단 페이지를 돌려준다
            // ("Client must be authenticated to access this resource."). 토큰이 정상이고
            // 이메일이 맞아도 마찬가지이고, 상태 코드가 자격증명 오류와 같아서 구분되지 않는다.
            //
            // 사용자에게 "클래식 토큰인가 스코프 토큰인가"를 물을 수는 없다 — 발급 화면의
            // 버튼 차이를 기억하는 사람은 드물고, 접두사도 같다. 그래서 앱이 알아낸다:
            // cloudId를 조회해 `api.atlassian.com/ex/jira/{cloudId}` 경로로 한 번 더 시도한다.
            //
            // 순서가 사이트 직접 → cloudId인 이유는 클래식 토큰이 더 흔하기 때문이다.
            // 클래식 사용자는 요청 1회로 끝나고, 스코프 사용자만 3회(거부 + tenant_info +
            // 재시도)를 쓴다. 로그인과 시작 시 한 번뿐이라 이 비용은 감당할 수 있다.
            guard let recovered = await retryOverCloudIdPath(creds, using: candidate) else {
                // 두 경로 모두 거부됐다 — 이제는 진짜 자격증명 문제로 본다.
                reportValidationFailure("이메일 또는 토큰이 올바르지 않습니다.",
                                        routing: failureRouting)
                return false
            }
            candidate = recovered.client
            me = recovered.user
        } catch {
            // 연결 자체가 안 된 것은 자격증명 문제가 아니다. 만료 배너로 라우팅된
            // 경로(시작 시 검증)에서도 결론은 같다 — 어느 쪽이든 지금은 쓸 수 없다.
            reportValidationFailure("Jira에 연결하지 못했습니다.", routing: failureRouting)
            return false
        }

        client = candidate
        // "내가 직접 옮긴 것만 XP"(스펙 §4.2)를 판정하려면 내가 누구인지 알아야 한다.
        // 여기가 accountId를 손에 넣는 유일한 지점이다.
        myAccountId = me.accountId
        // 티켓 링크를 만들 때 쓴다. APITokenAuth와 같은 정규화를 거쳐야 사용자가 어떻게
        // 입력했든 같은 호스트가 된다.
        siteHost = JiraSite.normalize(creds.site)
        // 방금 인증에 성공한 값이므로 힌트로 삼기에 가장 확실하다. 시작 시 채운 값이
        // 있어도 덮는다 — 계정을 바꿔 로그인한 경우 옛 이메일이 남으면 안 된다.
        rememberSignInHint(site: creds.site, email: creds.email)
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
        //
        // 바인딩은 accountId만이 아니라 **사이트까지** 담는다. Atlassian Cloud의
        // accountId는 사이트가 아니라 Atlassian 계정에 붙어서, 같은 사람이 다른 조직의
        // Jira로 옮겨도 accountId는 그대로다 — accountId만 보면 그 이동이 전환으로 잡히지
        // 않는다(AccountBinding 참고).
        do {
            let current = AccountBinding(site: creds.site, accountId: me.accountId)
            let bound = try accountBinding.load().map(AccountBinding.init(rawValue:))
            if let bound, !bound.identifiesSameAccount(as: current) {
                try? store.reset()
                // 채점 **입력**도 함께 버린다. 미러·이벤트만 지우면 이전 조직의 워크플로
                // 매핑과 백필이 추정한 폴백이 남아 `effectiveWorkflow()`에 계속 병합되고,
                // 새 계정의 전이가 남의 조직 기준으로 채점된다(WorkflowStore.clear 참고).
                try? workflow.clear()
                // 다른 테넌트에는 그 필드가 없다. 남겨두면 이전 사이트의 customfield_*를
                // 새 계정에도 계속 요청하게 되고, 새 사이트에 그 필드가 없으면 검색 요청
                // 전체가 거부될 수 있다(SyncEngine.swift 참고). 아래 조회가 새 사이트의
                // 값으로 다시 채운다 — 여기서는 지우기만 한다.
                try? sprintField.clear()
            }
            try? accountBinding.save(current.rawValue)
        } catch {
            // 미러도 바인딩도 건드리지 않는다. 지우는 쪽도 덮는 쪽도 되돌릴 수 없다.
        }

        // 스프린트 필드 ID를 한 번 찾아 저장한다. 실패해도 로그인을 막지 않는다 —
        // 스프린트를 쓰지 않는 사이트도 있고, 없다는 것은 오류가 아니라 사실이다.
        // 표시가 빠질 뿐 나머지는 그대로 돈다.
        //
        // 계정 전환 검사(바로 위) **뒤에** 두는 것이 중요하다: 전환이었다면 그 검사가 이미
        // sprintField를 지웠으므로 여기서는 새 사이트의 값만 채우면 된다. 앞에 두면 저장이
        // 먼저 끝난 뒤에야 전환 검사가 돌아 store·workflow만 지우고 sprintField는 그대로
        // 두게 되어, 이전 사이트의 필드 ID가 새 계정에 남는다(최종 전체 브랜치 리뷰 Finding 1).
        //
        // 조회 결과는 있는 그대로 기록한다(authoritative): 필드가 있으면 저장하고, 없으면
        // 지운다 — "없음"도 이번 조회가 확인한 사실이므로, 저장된 옛 값을 그대로 두면
        // 관리자가 사이트에서 스프린트 필드를 없앤 경우와 구분되지 않는다. 조회 자체가
        // 실패하면(네트워크 등) 건드리지 않는다 — 전환이었다면 위에서 이미 지워졌고,
        // 전환이 아니었다면 지금 저장된 값이 여전히 맞을 가능성이 높다.
        //
        // "실패"에는 카탈로그를 **읽지 못한 것**도 들어간다 — `try?`로 뭉뚱그리면
        // `sprintFieldID(in:)`이 던진 디코딩 실패와 "카탈로그는 읽었는데 스프린트
        // 필드가 없더라"가 같은 nil로 보인다. 전자는 이번 조회가 사이트를 증언한 게
        // 아니므로 지우면 안 된다(최종 전체 브랜치 리뷰 Finding 3).
        if let data = try? await candidate.fields() {
            do {
                if let id = try JiraFieldCatalog.sprintFieldID(in: data) {
                    try? sprintField.save(id)
                } else {
                    try? sprintField.clear()
                }
            } catch {
                // 카탈로그를 읽지 못했다 — "없음"이 아니라 "모른다"다. 저장된 값이
                // 있다면 손대지 않는다.
            }
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
        // 로그인 직후에도 집계가 채워지게 한다 — 백필을 돌리지 않은 사용자도 이미 쌓인
        // 이벤트로 계산된 값을 봐야 한다. 계정 전환 시 미러를 버리는 처리(위)가 끝난
        // **뒤**에 부르는 것이 중요하다: 먼저 부르면 이전 계정의 숫자가 잡힌다.
        await refreshDerivedState()
        return true
    }

    /// 힌트를 기억한다. 저장에 실패해도 조용히 넘어간다 — 힌트는 입력을 줄여 주는
    /// 편의일 뿐이고, 인증은 이미 성공했거나 진행 중이다. 실패를 화면에 올리면
    /// 사용자가 할 수 있는 일도 없이 경고만 늘어난다.
    private func rememberSignInHint(site: String, email: String) {
        let hint = SignInHint(site: site, email: email)
        signInHint = hint
        try? signInHintStore.save(hint.rawValue)
    }

    /// 사이트 직접 경로가 401을 돌려줬을 때, 스코프 토큰용 cloudId 경로로 한 번 더 시도한다.
    ///
    /// `probe`는 첫 시도에 쓴 클라이언트다 — 그 안의 HTTP 경로를 재사용해 `/_edge/tenant_info`를
    /// 부른다(그 엔드포인트는 인증이 필요 없다). 성공하면 새 클라이언트와 사용자 정보를,
    /// 어느 단계든 실패하면 `nil`을 돌려준다. 실패를 세분하지 않는 이유는 호출부의 처리가
    /// 같기 때문이다 — 이 경로가 안 되면 남은 결론은 "자격증명이 틀렸다" 하나뿐이다.
    private func retryOverCloudIdPath(
        _ creds: Credentials, using probe: JiraClient
    ) async -> (client: JiraClient, user: JiraUser)? {
        do {
            let cloudId = try await probe.cloudId(forSite: creds.site)
            let scoped = ScopedAPITokenAuth(
                cloudId: cloudId, email: creds.email, token: creds.token
            )
            let client = clientFactory(scoped)
            return (client, try await client.myself())
        } catch {
            return nil
        }
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

    /// 이 티켓에서 지금 고를 수 있는 전이. **캐싱하지 않는다** — 관리자가 워크플로를
    /// 바꾸면 캐시된 전이 ID는 즉시 틀린 값이 된다(v0.1 스펙 §8.5).
    public func availableTransitions(for issueKey: String) async throws -> [JiraTransition] {
        guard let client else { throw JiraError.unauthorized }
        return try await client.transitions(issueKey: issueKey)
    }

    /// 전이를 예약한다. 요청은 실행 취소 창이 지난 뒤에 나간다.
    public func requestTransition(issueKey: String, transition: JiraTransition) {
        // 미러에 없는 티켓은 화면에도 없으므로 사용자가 고를 수 있는 상황이 아니다 —
        // 조용히 무시한다.
        guard issues.contains(where: { $0.key == issueKey }) else { return }

        // 같은 티켓의 대기를 교체한다. 취소하고 다시 고르는 것과 결과가 같아야 한다.
        transitionTasks[issueKey]?.cancel()
        transitionFailures[issueKey] = nil

        let window = settings.transitionUndoWindow
        pendingTransitions[issueKey] = PendingTransition(
            issueKey: issueKey,
            transitionId: transition.id,
            toStatusName: transition.toStatusName,
            // `Duration.components.seconds`만 쓰면 서브초 성분(attoseconds)이 통째로
            // 잘린다 — `window`가 정수 초가 아니게 되는 순간(설정을 바꾸거나 테스트가
            // 밀리초 단위로 줄이는 경우) 카드가 그리는 카운트다운이 실제 타이머보다
            // 짧거나 길어 보인다. `fullSeconds`는 attoseconds까지 더해 정확한 초를 만든다.
            firesAt: clock().addingTimeInterval(window.fullSeconds)
        )
        transitionTasks[issueKey] = Task { [weak self, transitionSleep] in
            do {
                try await transitionSleep(window)
            } catch {
                // 취소됐다 — 요청을 보내지 않는다. 그것이 이 창의 전부다.
                return
            }
            guard !Task.isCancelled else { return }
            await self?.executeTransition(issueKey: issueKey)
        }
    }

    /// 대기 중인 전이를 되돌린다. Jira에는 아직 아무것도 보내지 않았다.
    public func cancelPendingTransition(issueKey: String) {
        transitionTasks[issueKey]?.cancel()
        transitionTasks[issueKey] = nil
        pendingTransitions[issueKey] = nil
    }

    public func dismissTransitionFailure(issueKey: String) {
        transitionFailures[issueKey] = nil
    }

    /// 실행 취소 창이 지난 뒤 실제로 요청을 보낸다.
    private func executeTransition(issueKey: String) async {
        guard let pending = pendingTransitions[issueKey], let client else {
            pendingTransitions[issueKey] = nil
            transitionTasks[issueKey] = nil
            return
        }
        // 결과와 무관하게 대기는 끝난다. 낙관적 표시를 남겨두면 실패했는데도 카드가
        // 새 레인에 머문다.
        pendingTransitions[issueKey] = nil
        transitionTasks[issueKey] = nil

        do {
            try await client.performTransition(issueKey: issueKey,
                                               transitionId: pending.transitionId)
        } catch JiraError.unauthorized {
            // 만료 배너가 이미 같은 사실을 말한다. 카드에도 실패를 띄우면 인증 문제가
            // 두 번 보이고, 사용자는 티켓 문제와 세션 문제를 구분하지 못한다.
            phase = .expired
            return
        } catch {
            transitionFailures[issueKey] = Self.transitionFailureMessage(error)
            return
        }

        // XP를 직접 주지 않는다. 동기화가 diff로 `.statusChanged`를 만들고 ScoreEngine이
        // 여느 이벤트와 똑같이 채점한다 — 점수가 관측 로그의 순수 함수라는 불변식을
        // 지키는 유일한 방법이고, 덕분에 AbuseGuard의 왕복 차단도 그대로 적용된다.
        await syncNow(reason: .manual)
    }

    /// 시트에 그릴 만큼만 받아온다. 더 필요하면 Jira로 보낸다 — 이 앱은 티켓을
    /// 읽는 도구가 아니라 정체를 재는 도구다.
    public static let commentPageSize = 20

    public func openDetail(issueKey: String) async {
        guard let client else { return }
        // 이 시트에 대해 이미 날아가고 있던 요청이 있다면 더 이상 그 결과를 기다리지
        // 않는다 — 새로 여는 티켓이 이제부터 "지금 시트가 기다리는 요청"이다.
        detailTask?.cancel()
        detailToken += 1
        let token = detailToken
        detailState = .loading(issueKey: issueKey)
        let generation = syncGeneration

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                // 이 태스크가 여전히 최신 요청일 때만 슬롯을 비운다 — 늦게 끝난 옛
                // 태스크가 그사이 새로 시작된 태스크의 참조를 지워버리면 `closeDetail()`이
                // 그 새 태스크를 더 이상 취소할 수 없게 된다.
                if self.detailToken == token { self.detailTask = nil }
            }
            do {
                let detail = try await client.issueDetail(issueKey: issueKey)
                // 상세를 받는 사이 시트가 닫혔거나 다른 티켓이 열렸으면(=더 이상 이
                // 요청을 기다리지 않으면) 댓글까지 마저 받아올 이유가 없다. 이 검사를
                // 여기 두지 않으면 로그아웃 뒤에도 댓글 요청이 옛 계정으로 나간다 —
                // "Jira와 더 이상 말하지 않는다"는 로그아웃의 첫 번째 의미를 어긴다.
                guard self.isCurrentDetailFetch(token: token, generation: generation) else { return }
                let comments = try await client.comments(issueKey: issueKey,
                                                         limit: Self.commentPageSize)
                // 받아오는 동안 시트가 닫혔거나, 다른 티켓이 열렸거나, 계정이 바뀌었으면
                // 이 결과는 지금 시트가 기다리는 것이 아니다.
                guard self.isCurrentDetailFetch(token: token, generation: generation) else { return }
                self.detailState = .loaded(IssueDetailView(
                    key: detail.key,
                    summary: detail.summary,
                    descriptionText: detail.description.map(ADFRenderer.plainText(from:)) ?? "",
                    comments: comments.map {
                        CommentView(id: $0.id, authorName: $0.authorName, created: $0.created,
                                    text: $0.body.map(ADFRenderer.plainText(from:)) ?? "")
                    }
                ))
            } catch JiraError.unauthorized {
                guard self.isCurrentDetailFetch(token: token, generation: generation) else { return }
                self.phase = .expired
                self.detailState = .idle
            } catch {
                guard self.isCurrentDetailFetch(token: token, generation: generation) else { return }
                // 앱이 직접 쓴 문구를 쓴다. `redactedErrorDescription`은 로그와 동기화
                // 이력을 위한 타입 이름(`JiraError.forbidden` 같은)이라 화면에 놓을 것이 아니다.
                self.detailState = .failed(Self.detailFailureMessage(error))
            }
        }
        detailTask = task
        await task.value
    }

    /// `token`이 지금도 `openDetail`이 기다리는 요청이고, 그사이 계정도 바뀌지
    /// 않았는지. 셋 중 하나라도 어긋나면 이 응답은 지금 시트가 기다리는 것이 아니다.
    private func isCurrentDetailFetch(token: Int, generation: Int) -> Bool {
        token == detailToken && generation == syncGeneration
    }

    public func closeDetail() {
        detailTask?.cancel()
        detailTask = nil
        // 늦게 도착하는 응답이 있어도 더 이상 기다리는 요청이 아니라고 답하도록.
        detailToken += 1
        detailState = .idle
    }

    /// 제목을 저장한다.
    ///
    /// 취소 창을 두지 않는 이유: 전이는 한 번 클릭이라 오조작이 쉽지만, 텍스트는
    /// 입력과 저장 버튼에 이미 숙고가 들어 있다.
    ///
    /// **충돌은 감지하지 않는다.** Jira Cloud의 `PUT /issue`에는 낙관적 잠금이 없어
    /// 409도 412도 오지 않는다. Jira 웹과 같은 마지막-쓰기-승리다.
    public func saveSummary(issueKey: String, summary: String) async {
        guard let client else { return }
        // 미러에 없는 티켓은 화면에도 없다 — 사용자가 고를 수 있는 상황이 아니다.
        guard issues.contains(where: { $0.key == issueKey }) else { return }
        guard !editInFlight.contains(issueKey) else { return }

        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        editInFlight.insert(issueKey)
        editFailures[issueKey] = nil
        let generation = syncGeneration

        // `AppModel`은 `@Observable @MainActor`다. 이 `Task`는 같은 격리를 물려받으므로
        // 안에서 상태를 직접 만져도 되고, 정리를 중첩 `Task`로 미루지 않아 완료 시점이
        // 확정된다 — 미루면 `await task.value`가 돌아온 뒤에도 `editInFlight`가
        // 잠깐 남아 있어 호출자가 본 상태와 실제가 어긋난다.
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishEdit(issueKey: issueKey) }
            do {
                try await client.updateSummary(issueKey: issueKey, summary: trimmed)
            } catch JiraError.unauthorized {
                // 만료 배너가 이미 같은 사실을 말한다. 시트에도 실패를 띄우면 인증
                // 문제가 두 번 보이고, 사용자는 티켓 문제와 세션 문제를 구분하지 못한다.
                if generation == self.syncGeneration { self.phase = .expired }
                return
            } catch {
                if generation == self.syncGeneration {
                    self.editFailures[issueKey] = Self.editFailureMessage(error)
                }
                return
            }
            // 저장하는 동안 계정이 바뀌었으면 이 결과는 남의 것이다.
            guard generation == self.syncGeneration else { return }
            // XP를 직접 주지 않는다. 동기화가 관측해 여느 이벤트와 똑같이 처리한다 —
            // 점수가 관측 로그의 순수 함수라는 불변을 지키는 유일한 방법이다.
            // 제목 수정은 미러의 summary를 갱신해야 카드의 제목이 맞는다.
            await self.syncNow(reason: .manual)
        }
        editTasks[issueKey] = task
        await task.value
    }

    /// 댓글을 등록한다.
    ///
    /// 보내는 ADF는 우리가 처음부터 만든다 — 읽어온 문서를 되돌려 보내지 않으므로
    /// 왕복 손실이 없다.
    ///
    /// 반환값은 실제로 등록됐는지만 말한다. 시트가 이 값으로 초안을 지울지
    /// 정하므로, `editFailures`의 부재로 성공을 추론하면 안 된다 — 401은
    /// 만료 배너와 중복되지 않도록 `editFailures`를 일부러 비워 두는데, 그
    /// 상태는 성공과 구분되지 않기 때문이다.
    @discardableResult
    public func postComment(issueKey: String, text: String) async -> Bool {
        guard let client else { return false }
        // 미러에 없는 티켓은 화면에도 없다 — 사용자가 고를 수 있는 상황이 아니다.
        guard issues.contains(where: { $0.key == issueKey }) else { return false }
        guard !editInFlight.contains(issueKey) else { return false }
        // 공백만 친 뒤 저장을 누른 것은 등록 의사가 아니다 — 상태도 건드리지 않고 그냥 돌아간다.
        guard let document = ADFBuilder.paragraphs(from: text) else { return false }

        editInFlight.insert(issueKey)
        editFailures[issueKey] = nil
        let generation = syncGeneration

        let work = Task { [weak self] () -> Bool in
            guard let self else { return false }
            defer { self.finishEdit(issueKey: issueKey) }
            do {
                try await client.addComment(issueKey: issueKey, body: document)
            } catch JiraError.unauthorized {
                if generation == self.syncGeneration { self.phase = .expired }
                return false
            } catch {
                if generation == self.syncGeneration {
                    self.editFailures[issueKey] = Self.editFailureMessage(error)
                }
                return false
            }
            // 등록하는 동안 계정이 바뀌었으면 이 결과는 남의 것이다 — 그래도 댓글
            // 자체는 Jira에 실제로 남았으므로 반환값은 true다.
            guard generation == self.syncGeneration else { return true }
            // 댓글은 `updated` 타임스탬프를 움직인다 — 다음 동기화가 `.touched`로
            // 관측하게 둔다. XP를 직접 주지 않는다.
            await self.syncNow(reason: .manual)
            return true
        }
        // `editTasks`는 `Task<Void, Never>`를 저장한다(`saveSummary`도 같은 딕셔너리를
        // 쓴다) — `work`는 `Bool`을 반환하므로 그대로 넣을 수 없다. 취소 전달을 잃지
        // 않도록 감싸기만 하는 `Void` 래퍼를 대신 저장하고, `signOut`의 `.cancel()`이
        // 이 래퍼에 오면 `withTaskCancellationHandler`가 `work`로 그대로 넘긴다.
        editTasks[issueKey] = Task {
            await withTaskCancellationHandler {
                _ = await work.value
            } onCancel: {
                work.cancel()
            }
        }
        return await work.value
    }

    public func dismissEditFailure(issueKey: String) {
        editFailures[issueKey] = nil
    }

    private func finishEdit(issueKey: String) {
        editInFlight.remove(issueKey)
        editTasks[issueKey] = nil
    }

    /// 화면에 띄울 실패 안내. **Jira가 준 사유를 옮기지 않는다.**
    ///
    /// 400은 `JiraError.transitionRejected(reason:)`로 들어오고 그 `reason`은 Jira
    /// 응답의 `errorMessages`를 그대로 담는다. 본문에는 이메일이 섞일 수 있다.
    private static func editFailureMessage(_ error: any Error) -> String {
        switch error {
        case JiraError.transitionRejected:
            return "Jira가 이 수정을 받지 않았습니다. Jira에서 확인해 주세요."
        case JiraError.offline:
            return "연결되지 않았습니다. 다시 시도해 주세요."
        case JiraError.forbidden:
            return "이 티켓을 수정할 권한이 없습니다."
        case JiraError.notFound:
            return "티켓을 찾을 수 없습니다."
        default:
            return "저장하지 못했습니다. 다시 시도해 주세요."
        }
    }

    /// 시트에 띄울 조회 실패 안내. **Jira가 준 사유를 옮기지 않는다.**
    ///
    /// 400은 `JiraError.transitionRejected(reason:)`로 들어오고 그 `reason`은 Jira 응답의
    /// `errorMessages`를 그대로 담는다. 본문에는 이메일이 섞일 수 있다.
    ///
    /// 시트 조회는 동기화 경로 밖에서 돌기 때문에 이 처리를 물려받지 못한다 — 여기서 직접 한다.
    private static func detailFailureMessage(_ error: any Error) -> String {
        switch error {
        case JiraError.offline:
            return "연결되지 않았습니다. 다시 시도해 주세요."
        case JiraError.forbidden:
            return "이 티켓을 볼 권한이 없습니다."
        case JiraError.notFound:
            return "티켓을 찾을 수 없습니다."
        default:
            return "티켓을 불러오지 못했습니다. 다시 시도해 주세요."
        }
    }

    /// 화면에 띄울 실패 안내. **Jira가 준 사유를 옮기지 않는다.**
    ///
    /// `JiraError.transitionRejected(reason:)`는 Jira 응답의 `errorMessages`를 그대로
    /// 담고 그 본문에는 이메일이 섞일 수 있다(`redactedErrorDescription` 참고).
    /// v0.1 스펙 §8.4는 화면에 닿는 실패 문자열까지 이 제약 아래 둔다.
    ///
    /// 사유 대신 Jira로 가는 길을 준다 — 전이가 거부되는 이유는 앱이 채울 수 없는
    /// 정보를 Jira가 요구하기 때문이고, 그것을 채울 수 있는 곳은 어차피 Jira다.
    private static func transitionFailureMessage(_ error: any Error) -> String {
        switch error {
        case JiraError.transitionRejected:
            return "Jira가 이 전이를 거부했습니다. 필요한 정보를 Jira에서 채워 주세요."
        case JiraError.offline:
            return "연결되지 않았습니다. 다시 시도해 주세요."
        case JiraError.forbidden:
            return "이 티켓을 옮길 권한이 없습니다."
        case JiraError.notFound:
            return "티켓을 찾을 수 없습니다. Jira에서 삭제되었을 수 있습니다."
        case JiraError.rateLimited:
            return "요청이 너무 잦습니다. 잠시 뒤 다시 시도해 주세요."
        default:
            return "전이하지 못했습니다. 잠시 뒤 다시 시도해 주세요."
        }
    }

    /// 테스트가 동기화 없이 보드 상태를 준비하기 위한 통로.
    ///
    /// 프로덕션 경로는 `recomputeFromLog()`뿐이다. 이 함수를 프로덕션 코드에서 부르면
    /// 미러와 화면이 갈라진다.
    func seedIssuesForTesting(_ seeded: [ObservedIssue]) {
        issues = seeded.sorted { $0.key < $1.key }
    }

    /// 대기 중인 전이 타이머 개수. `transitionTasks`는 `private`이라 테스트가 직접 보지
    /// 못한다 — `signOut()`이 타이머를 실제로 취소·정리하는지(딕셔너리만 비우고 태스크는
    /// 살려두는 게 아닌지)를 이 통로 없이는 검증할 수 없다.
    var transitionTaskCountForTesting: Int { transitionTasks.count }
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

extension Duration {
    /// 초 단위 실수값. `components.seconds`만 쓰면 attoseconds 성분이 통째로 버려져
    /// 정수 초가 아닌 `Duration`(예: 테스트가 밀리초로 줄인 실행 취소 창)에서 결과가
    /// 잘린다 — `PendingTransition.firesAt` 계산이 이 오차에 그대로 노출된다.
    var fullSeconds: Double {
        let comps = components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1_000_000_000_000_000_000
    }
}
