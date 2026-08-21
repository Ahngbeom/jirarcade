import Foundation
import SwiftData
import JiraKit

/// changelog를 가져오는 방법을 추상화한다. 덕분에 엔진 테스트가 HTTP 없이 돈다.
public protocol ChangelogSource: Sendable {
    func fetchPage(jql: String, pageToken: String?)
        async throws -> (issues: [JiraIssueWithChangelog], nextPageToken: String?)
    func fetchIssueChangelog(key: String, startAt: Int) async throws -> JiraChangelogPage
    func fetchStatusCatalog() async throws -> [JiraStatusCatalogEntry]
}

/// 실제 Jira를 쓰는 구현.
public struct JiraChangelogSource: ChangelogSource {
    private let client: JiraClient
    private let pageSize: Int

    public init(client: JiraClient, pageSize: Int = 100) {
        self.client = client
        self.pageSize = pageSize
    }

    public func fetchPage(jql: String, pageToken: String?)
        async throws -> (issues: [JiraIssueWithChangelog], nextPageToken: String?) {
        try await client.searchIssuesWithChangelog(
            jql: jql, maxResults: pageSize, pageToken: pageToken
        )
    }

    public func fetchIssueChangelog(key: String, startAt: Int) async throws -> JiraChangelogPage {
        try await client.issueChangelog(issueKey: key, startAt: startAt)
    }

    public func fetchStatusCatalog() async throws -> [JiraStatusCatalogEntry] {
        try await client.statusCatalog()
    }
}

public struct BackfillOutcome: Sendable, Equatable {
    public let insertedEvents: Int
    public let processedIssues: Int
    public let discoveredStatuses: [String]
    public let partiallyRestored: [String]
    /// 폴백(②)으로 해석한 매핑. 호출부가 저장해 두었다가 채점기를 만들 때
    /// `WorkflowMap.merging`으로 합친다(Task 10b). 이게 없으면 폴백은
    /// 마법사 후보 목록만 만들고 XP에는 아무 영향이 없다.
    public let resolvedFallbacks: [String: Stage]
    /// 상태 카탈로그를 못 받아 폴백 ②가 비활성인 채로 돌았다.
    /// 사용자에게 "이번 백필은 정확도가 낮다"고 알릴 근거다.
    public let catalogUnavailable: Bool
}

public enum BackfillError: Error, Equatable {
    /// 서버가 같은 페이지 토큰을 다시 줬다. 그대로 두면 무한 루프다.
    case repeatedPageToken
}

/// 페이지를 훑으며 changelog를 이벤트로 바꿔 저장한다.
///
/// 이 타입이 하는 일은 조율뿐이다 — 번역은 `ChangelogParser`, 폴백은 `StatusCatalog`,
/// 중복 방지는 `ArcadeStore`가 맡는다.
@MainActor
public final class BackfillEngine {
    private let source: any ChangelogSource
    private let store: ArcadeStore
    private let workflow: WorkflowMap
    private let parser = ChangelogParser()

    public init(source: any ChangelogSource, store: ArcadeStore, workflow: WorkflowMap) {
        self.source = source
        self.store = store
        self.workflow = workflow
    }

    /// - Parameters:
    ///   - totalIssueCount: 진행률 표시용 총계. 새 검색 API는 total을 주지 않으므로
    ///     호출부가 따로 세어 넘기거나, 모르면 nil을 넘긴다. 모를 때 처리한 수를
    ///     총계로 삼으면 진행률이 늘 100%로 보인다.
    ///   - resume: true면 중단된 백필을 이어받는다. 범위(jql)가 달라졌으면 이어받지
    ///     않고 새로 시작한다 — 다른 범위의 진행 상황은 이어붙일 수 없다.
    ///   - progress: (처리한 티켓 수, 총계 또는 nil). 페이지마다 불린다.
    public func run(
        jql: String,
        now: Date,
        totalIssueCount: Int? = nil,
        resume: Bool = false,
        progress: @MainActor (Int, Int?) -> Void
    ) async throws -> BackfillOutcome {
        // 카탈로그 조회 실패는 진행을 막지 않는다 — 폴백 ②만 잃고 ①③은 남는다(스펙 §8).
        // 다만 취소는 삼키면 안 된다. try?로 뭉뚱그리면 사용자가 중단을 눌러도
        // 카탈로그 단계에서만 조용히 넘어가고 백필이 계속 돈다.
        var catalogUnavailable = false
        var entries: [JiraStatusCatalogEntry] = []
        do {
            entries = try await source.fetchStatusCatalog()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            catalogUnavailable = true
        }
        let catalog = StatusCatalog(workflow: workflow, entries: entries)

        // 이어받기: 같은 범위의 미완료 run이 있으면 그 지점부터 간다.
        // beginBackfill은 미완료 run을 지우므로, 이어받을 때는 부르지 않는다.
        let existing: ArcadeStore.BackfillSnapshot? = resume ? try store.resumableBackfill() : nil
        let runId: PersistentIdentifier
        var token: String?
        var processed: Int
        if let existing, existing.jql == jql {
            runId = existing.id
            token = existing.nextPageToken
            processed = existing.processedIssueCount
        } else {
            runId = try store.beginBackfill(jql: jql, at: now,
                                            totalIssueCount: totalIssueCount ?? 0)
            token = nil
            processed = 0
        }

        // 실패해도 여기까지 넣은 이벤트는 유효하고 진행 지점이 저장돼 있다.
        // run을 미완료로 남기면 다음 실행에서 "이어서 하시겠습니까"가 뜬다 —
        // 그게 맞는 동작이므로 실패 경로에서는 finishBackfill로 닫지 않는다.
        let outcome = try await walk(
            jql: jql, runId: runId, catalog: catalog,
            catalogUnavailable: catalogUnavailable,
            token: token, processed: processed,
            totalIssueCount: totalIssueCount, progress: progress
        )
        try store.finishBackfill(runId, at: now, failure: nil)
        return outcome
    }

    private func walk(
        jql: String, runId: PersistentIdentifier, catalog: StatusCatalog,
        catalogUnavailable: Bool, token startToken: String?, processed startProcessed: Int,
        totalIssueCount: Int?, progress: @MainActor (Int, Int?) -> Void
    ) async throws -> BackfillOutcome {
        var token = startToken
        var processed = startProcessed
        var inserted = 0
        var partiallyRestored: [String] = []
        // 서버가 같은 토큰을 다시 주면 영원히 돈다. 1,000여 건을 훑는 동안
        // 한 번이라도 그러면 앱이 멈춘 것처럼 보인다.
        var seenTokens = Set<String>()

        repeat {
            // 사용자가 중단하면 여기서 빠져나온다. 페이지 경계에서만 검사하는 이유는
            // 이미 넣은 이벤트는 유효하고, 중단 지점의 nextPageToken이 저장돼 있어
            // 나중에 이어서 진행할 수 있기 때문이다 — 롤백할 것이 없다.
            try Task.checkCancellation()

            if let token, !seenTokens.insert(token).inserted {
                throw BackfillError.repeatedPageToken
            }

            let page = try await source.fetchPage(jql: jql, pageToken: token)

            for issue in page.issues {
                let resolved = await resolve(issue: issue, partiallyRestored: &partiallyRestored)
                let transitions = parser.parse(issue: resolved)

                // 폴백 판정을 태워 미매핑 상태와 폴백 매핑을 수집한다. 반환값은 쓰지 않지만
                // catalog가 내부에 쌓고, 그 결과가 마법사 후보와 실효 맵이 된다.
                for transition in transitions {
                    _ = catalog.stage(forId: transition.fromStatusId,
                                      name: transition.event.fromStatus)
                    _ = catalog.stage(forId: transition.toStatusId,
                                      name: transition.event.toStatus)
                }

                inserted += try store.appendBackfillEvents(
                    transitions.map(\.event), historyIds: transitions.map(\.historyId)
                )
                processed += 1
            }

            token = page.nextPageToken

            // 진행 상황을 페이지 경계마다 저장한다. 여기서 저장하지 않으면
            // 중단 시 이어받을 지점이 없어 1,000여 건을 처음부터 다시 훑는다.
            try store.advanceBackfill(
                runId, nextPageToken: token, processedIssueCount: processed,
                discovered: catalog.unmappedNames.sorted(),
                partiallyRestored: partiallyRestored
            )
            progress(processed, totalIssueCount)
        } while token != nil

        return BackfillOutcome(
            insertedEvents: inserted,
            processedIssues: processed,
            discoveredStatuses: catalog.unmappedNames.sorted(),
            partiallyRestored: partiallyRestored,
            resolvedFallbacks: catalog.resolvedFallbacks,
            catalogUnavailable: catalogUnavailable
        )
    }

    /// changelog가 잘려 왔으면 보충 조회로 채운다. 실패하면 원래 것을 그대로 쓰고
    /// 부분 복원으로 기록한다 — 한 티켓 때문에 전체를 멈추지 않는다.
    private func resolve(
        issue: JiraIssueWithChangelog, partiallyRestored: inout [String]
    ) async -> JiraIssueWithChangelog {
        guard issue.changelog.isTruncated else { return issue }
        do {
            let full = try await fetchWholeChangelog(key: issue.key)
            return JiraIssueWithChangelog(
                key: issue.key, createdAt: issue.createdAt,
                dueDate: issue.dueDate, changelog: full
            )
        } catch {
            partiallyRestored.append(issue.key)
            return issue
        }
    }

    /// 보충 조회도 페이지네이션된다. `issueChangelog`는 한 번에 100건까지만 주므로
    /// 한 번 부르고 마는 것으로는 history가 100건을 넘는 오래된 티켓이 여전히 잘린다.
    private func fetchWholeChangelog(key: String) async throws -> JiraChangelogPage {
        var histories: [JiraChangelogHistory] = []
        var startAt = 0
        var total = 0

        while true {
            try Task.checkCancellation()
            let page = try await source.fetchIssueChangelog(key: key, startAt: startAt)
            total = page.total
            // 서버가 빈 페이지를 주면 더 받을 게 없다. 이 검사가 없으면
            // total이 실제보다 큰 경우에 무한 루프가 된다.
            guard !page.histories.isEmpty else { break }
            histories.append(contentsOf: page.histories)
            guard histories.count < total else { break }
            startAt = histories.count
        }

        return JiraChangelogPage(startAt: 0, maxResults: histories.count,
                                 total: max(total, histories.count), histories: histories)
    }
}
