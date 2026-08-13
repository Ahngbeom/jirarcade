import Foundation
import JiraKit

/// 티켓을 가져오는 방법을 추상화한다. 덕분에 SyncEngine 테스트가 HTTP 없이 돈다.
public protocol IssueSource: Sendable {
    /// 페치는 시간 의존 동작이 아니므로 `now`를 받지 않는다.
    func fetchAssignedIssues(jql: String) async throws -> [ObservedIssue]
}

/// 실제 Jira를 쓰는 구현. 페이지네이션을 모두 소진해 한 번에 돌려준다.
public struct JiraIssueSource: IssueSource {
    private let client: JiraClient
    private let fields = [
        "summary", "status", "issuetype", "priority", "assignee", "duedate", "updated",
    ]

    public init(client: JiraClient) {
        self.client = client
    }

    public func fetchAssignedIssues(jql: String) async throws -> [ObservedIssue] {
        var collected: [ObservedIssue] = []
        var token: String?

        repeat {
            let page = try await client.searchIssues(
                jql: jql, fields: fields, maxResults: 100, pageToken: token
            )
            collected.append(contentsOf: page.issues.map(ObservedIssue.init))
            token = page.nextPageToken
        } while token != nil

        return collected
    }
}

public struct SyncOutcome: Sendable {
    public let newEvents: [DomainEvent]
    public let summary: PlayerSummary
}

/// 페치 → diff → 저장 → 재집계를 한 번의 호출로 묶는다.
@MainActor
public final class SyncEngine {
    private let source: any IssueSource
    private let store: ArcadeStore
    private let diffEngine = DiffEngine()
    private let scoreEngine: ScoreEngine

    public init(
        source: any IssueSource, store: ArcadeStore,
        rules: RuleSet, workflow: WorkflowMap, calendar: Calendar
    ) {
        self.source = source
        self.store = store
        self.scoreEngine = ScoreEngine(rules: rules, workflow: workflow, calendar: calendar)
    }

    public func sync(jql: String, now: Date) async throws -> SyncOutcome {
        let runID = try store.beginSyncRun(at: now)

        let fetched: [ObservedIssue]
        do {
            fetched = try await source.fetchAssignedIssues(jql: jql)
        } catch {
            // try?인 이유: 이력 기록이 실패해도 원래 에러를 삼키면 안 된다.
            // 이중 실패는 드물지만 그때가 진단이 가장 필요한 순간이다.
            try? store.finishSyncRun(runID, at: now, issueCount: 0,
                                     failure: String(describing: error))
            throw error
        }

        let previous = try store.loadMirror()
        let events = diffEngine.diff(previous: previous, current: fetched, observedAt: now)
        try store.applySync(issues: fetched, events: events, observedAt: now)
        // 0건은 실패가 아니라 메모다. failureMessage에 넣으면 이 동기화가
        // observationDayCount의 "성공한 동기화"에서 배제되어 관측 일수가 어긋난다.
        try store.finishSyncRun(runID, at: now, issueCount: fetched.count, failure: nil,
                                note: Self.emptyFetchNote(fetched: fetched, previous: previous))

        let allEvents = try store.loadEvents()
        let mirror = try store.loadMirror()
        let (_, summary) = scoreEngine.recompute(events: allEvents, issues: mirror, now: now)

        return SyncOutcome(newEvents: events, summary: summary)
    }

    /// 페치는 성공했는데 결과가 0건인 상황을 깨끗한 성공으로 기록하면 전량 손실이
    /// 조용히 지나간다 — 이슈 단위 디코딩 실패는 예외가 아니라 빈 배열로 나타나기 때문이다.
    /// 사용자에게는 "동기화 성공, 마지막 미러 표시 중"으로 보이고 어디에도 흔적이 없다.
    private static func emptyFetchNote(
        fetched: [ObservedIssue], previous: [String: ObservedIssue]
    ) -> String? {
        guard fetched.isEmpty else { return nil }
        return previous.isEmpty
            ? "페치 성공, 결과 0건"
            : "페치 성공, 결과 0건 (직전 미러 \(previous.count)건)"
    }
}
