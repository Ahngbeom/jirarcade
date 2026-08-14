import Foundation
import JiraKit

/// 티켓을 가져오는 방법을 추상화한다. 덕분에 SyncEngine 테스트가 HTTP 없이 돈다.
public protocol IssueSource: Sendable {
    /// 페치는 시간 의존 동작이 아니므로 `now`를 받지 않는다.
    func fetchAssignedIssues(jql: String) async throws -> FetchResult
}

/// `IssueSource.fetchAssignedIssues`의 결과. 튜플이 아니라 struct인 이유: 나중에 필드가
/// 늘어나도(이미 `SyncOutcome`이 한 번 그랬듯) 모든 호출부가 깨지지 않는다.
public struct FetchResult: Sendable, Equatable {
    public let issues: [ObservedIssue]
    /// 개별 이슈 디코딩 실패 건수. `JiraSearchResponse.decode`는 실패한 이슈를 건너뛰고
    /// 배열에서 조용히 빼므로, 이 값이 없으면 "전량 디코딩 실패"가 "할 일 없음"과 구분되지 않는다.
    public let decodingFailures: Int

    public init(issues: [ObservedIssue], decodingFailures: Int = 0) {
        self.issues = issues
        self.decodingFailures = decodingFailures
    }
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

    public func fetchAssignedIssues(jql: String) async throws -> FetchResult {
        var collected: [ObservedIssue] = []
        var failures = 0
        var token: String?

        repeat {
            let page = try await client.searchIssues(
                jql: jql, fields: fields, maxResults: 100, pageToken: token
            )
            collected.append(contentsOf: page.issues.map(ObservedIssue.init))
            failures += page.failures.count
            token = page.nextPageToken
        } while token != nil

        return FetchResult(issues: collected, decodingFailures: failures)
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

        let fetched: FetchResult
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
        let events = diffEngine.diff(previous: previous, current: fetched.issues, observedAt: now)
        try store.applySync(issues: fetched.issues, events: events, observedAt: now)
        // 0건과 디코딩 실패는 실패가 아니라 메모다. failureMessage에 넣으면 이 동기화가
        // observationDayCount의 "성공한 동기화"에서 배제되어 관측 일수가 어긋난다.
        try store.finishSyncRun(runID, at: now, issueCount: fetched.issues.count, failure: nil,
                                note: Self.syncNote(fetched: fetched, previous: previous))

        let allEvents = try store.loadEvents()
        let mirror = try store.loadMirror()
        let (_, summary) = scoreEngine.recompute(events: allEvents, issues: mirror, now: now)

        return SyncOutcome(newEvents: events, summary: summary)
    }

    /// 페치는 성공했는데 결과가 0건이거나 일부(전부) 디코딩에 실패한 상황을 깨끗한
    /// 성공으로 기록하면 손실이 조용히 지나간다 — 이슈 단위 디코딩 실패는 예외가 아니라
    /// 빈 배열/축소된 배열로만 나타나기 때문이다. 디코딩 실패가 있으면 그 사실이 우선이고,
    /// 결과가 0건이었다는 사실은 "0건 반영"이라는 문구로 이미 담긴다.
    private static func syncNote(
        fetched: FetchResult, previous: [String: ObservedIssue]
    ) -> String? {
        if fetched.decodingFailures > 0 {
            return "\(fetched.decodingFailures)건 파싱 실패 (\(fetched.issues.count)건 반영)"
        }
        guard fetched.issues.isEmpty else { return nil }
        return previous.isEmpty
            ? "페치 성공, 결과 0건"
            : "페치 성공, 결과 0건 (직전 미러 \(previous.count)건)"
    }
}
