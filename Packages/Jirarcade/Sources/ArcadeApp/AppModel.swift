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

    private let store: ArcadeStore
    private let credentials: any CredentialStore
    private let workflow: any WorkflowStore
    private let clientFactory: (any AuthProvider) -> JiraClient
    private let clock: () -> Date
    private let calendar: Calendar

    /// 로그인 후에만 존재한다. 매핑 조회와 동기화에 쓴다.
    private var client: JiraClient?

    public init(
        store: ArcadeStore,
        credentials: any CredentialStore,
        workflow: any WorkflowStore,
        clientFactory: @escaping (any AuthProvider) -> JiraClient,
        clock: @escaping () -> Date,
        calendar: Calendar
    ) {
        self.store = store
        self.credentials = credentials
        self.workflow = workflow
        self.clientFactory = clientFactory
        self.clock = clock
        self.calendar = calendar
    }

    /// 앱 시작. 저장된 자격증명이 있으면 확인하고 적절한 단계로 보낸다.
    public func start() async {
        phase = .launching
        guard let saved = try? credentials.load() else {
            phase = .signedOut(message: nil)
            return
        }
        await validate(saved, persistOnSuccess: false)
    }

    /// 로그인 화면에서 호출한다.
    public func signIn(site: String, email: String, token: String) async {
        phase = .validating
        await validate(Credentials(site: site, email: email, token: token), persistOnSuccess: true)
    }

    public func signOut() async {
        try? credentials.clear()
        client = nil
        summary = nil
        lastSync = nil
        phase = .signedOut(message: nil)
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
        if persistOnSuccess { try? credentials.save(creds) }
        await routeAfterAuthentication()
    }

    /// 인증이 끝난 뒤 매핑 유무로 갈린다.
    private func routeAfterAuthentication() async {
        if (try? workflow.load()) ?? nil != nil {
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
