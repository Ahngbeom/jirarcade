import Foundation
import SwiftData
import JiraKit

/// changelog를 가져오는 방법을 추상화한다. 덕분에 엔진 테스트가 HTTP 없이 돈다.
public protocol ChangelogSource: Sendable {
    func fetchPage(jql: String, pageToken: String?)
        async throws -> (issues: [JiraIssueWithChangelog], nextPageToken: String?)
    func fetchIssueChangelog(key: String, startAt: Int) async throws -> JiraChangelogPage
    func fetchStatusCatalog() async throws -> [JiraStatusCatalogEntry]
    /// 진행률 표시용 총계. 새 검색 API는 응답에 total을 주지 않으므로 따로 물어야 한다.
    func approximateIssueCount(jql: String) async throws -> Int
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

    public func approximateIssueCount(jql: String) async throws -> Int {
        try await client.approximateIssueCount(jql: jql)
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
    ///   - resume: true면 중단된 백필을 이어받는다. 범위(jql)가 달라졌으면 이어받지
    ///     않고 새로 시작한다 — 다른 범위의 진행 상황은 이어붙일 수 없다.
    ///   - progress: (처리한 티켓 수, 총계 또는 nil). 페이지마다 불린다.
    ///     총계는 엔진이 직접 물어 채운다(`approximateIssueCount`) — 모를 때 처리한 수를
    ///     총계로 삼으면 진행률이 늘 100%로 보이므로 그때는 nil로 둔다.
    public func run(
        jql: String,
        now: Date,
        resume: Bool = false,
        progress: @MainActor (Int, Int?) -> Void
    ) async throws -> BackfillOutcome {
        // 카탈로그 조회 실패는 진행을 막지 않는다 — 폴백 ②만 잃고 ①③은 남는다.
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
        let total: Int?
        if let existing, existing.jql == jql {
            runId = existing.id
            token = existing.nextPageToken
            processed = existing.processedIssueCount
            // 저장된 총계를 쓰되 0이면 다시 묻는다 — 옛 run이거나 그때 조회에 실패한 run이다.
            if existing.totalIssueCount > 0 {
                total = existing.totalIssueCount
            } else {
                total = try await approximateTotal(jql: jql)
                if let total { try store.recordBackfillTotal(runId, totalIssueCount: total) }
            }
            // 재시도가 시작된 이상 옛 실패는 더 이상 최신 사실이 아니다. 지우지 않으면
            // 사용자가 이어받은 뒤 스스로 중단했을 때(취소는 사유를 적지 않는다)
            // 화면이 지난 실패 문구를 그대로 보여준다.
            try store.clearBackfillFailure(runId)
        } else {
            total = try await approximateTotal(jql: jql)
            runId = try store.beginBackfill(jql: jql, at: now, totalIssueCount: total ?? 0)
            token = nil
            processed = 0
        }

        // 카탈로그를 못 받은 사실은 **run 행에** 적는다. 메모리에 두면 실패로 끝난 실행·
        // 앱 재시작·이어받기에서 사라진다(BackfillRun.catalogUnavailable 참고).
        // 누적이므로 이어받기가 카탈로그를 받아도 1회차의 표시는 남는다.
        if catalogUnavailable { try store.markBackfillCatalogUnavailable(runId) }

        // 실패해도 여기까지 넣은 이벤트는 유효하고 진행 지점이 저장돼 있다.
        // run을 미완료로 남기면 다음 실행에서 "이어서 하시겠습니까"가 뜬다 —
        // 그게 맞는 동작이므로 실패 경로에서는 finishBackfill로 닫지 않는다.
        do {
            let outcome = try await walk(
                jql: jql, runId: runId, catalog: catalog,
                catalogUnavailable: catalogUnavailable,
                token: token, processed: processed,
                totalIssueCount: total, progress: progress
            )
            try store.finishBackfill(runId, at: now, failure: nil)
            return outcome
        } catch is CancellationError {
            // 사용자가 스스로 누른 중단은 실패가 아니다. 사유를 적으면 다음 실행에서
            // "지난 백필이 실패했습니다"가 뜬다 — run은 미완료로만 남겨 재개 대상이 되게 한다.
            throw CancellationError()
        } catch {
            // 사유만 적고 run은 미완료로 둔다. finishedAt을 채우면 재개 대상에서 빠져
            // 여기까지 받은 1,000여 건의 진행 지점을 버리게 된다.
            // 기록 자체가 실패해도 원래 에러를 가리면 안 되므로 try?로 넘긴다.
            try? store.recordBackfillFailure(runId, message: Self.failureDescription(error))
            throw error
        }
    }

    /// 진행률에 쓸 총계. **조회 실패는 백필을 막지 않는다** — 진행률이 불확정 바가 될 뿐이라
    /// 카탈로그 조회와 같은 결로 다룬다.
    ///
    /// 취소만은 다시 던진다. `try?`로 뭉뚱그리면 사용자가 중단을 눌러도 이 단계에서만
    /// 조용히 넘어가고 백필이 계속 돈다 — 이 저장소에서 두 번 나온 결함이다.
    private func approximateTotal(jql: String) async throws -> Int? {
        do {
            return try await source.approximateIssueCount(jql: jql)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// 저장할 실패 사유. 설정 화면에 그대로 노출되므로 조직 정보가 섞이면 안 된다.
    ///
    /// `localizedDescription`이나 `String(describing:)`에는 호스트·JQL·토큰 조각이 실려 올 수
    /// 있어 타입 이름만 남긴다. 우리가 정의한 에러는 케이스 이름 자체가 진단이고 조직 정보를
    /// 담지 않으므로 그것만 예외로 둔다. (`ArcadeApp`의 `redactedErrorDescription`은
    /// 모듈 경계상 `ArcadeCore`에서 쓸 수 없다.)
    private static func failureDescription(_ error: any Error) -> String {
        if let error = error as? BackfillError { return "BackfillError.\(error)" }
        return String(describing: type(of: error))
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

            // 페이지 하나 분량을 모았다가 한 번에 넣는다. 티켓마다 부르면
            // appendBackfillEvents가 호출마다 기존 백필 이벤트를 전량 조회하므로 2차식이 된다
            // (실측: 티켓 800건 46초). 엔진은 @MainActor이고 스토어 호출은 동기라 그동안 UI가 멈춘다.
            var pageEvents: [DomainEvent] = []
            var pageHistoryIds: [String] = []
            // 이 페이지에서 changelog를 온전히 받은 티켓. 스토어가 이 티켓들의 라이브 관측
            // 전이를 백필 이벤트로 대체한다(appendBackfillEvents 참고).
            var pageFullyRestored = Set<String>()

            for issue in page.issues {
                let (resolved, fullyRestored) = try await resolve(
                    issue: issue, partiallyRestored: &partiallyRestored
                )
                if fullyRestored { pageFullyRestored.insert(issue.key) }
                let transitions = parser.parse(issue: resolved)

                // 폴백 판정을 태워 미매핑 상태와 폴백 매핑을 수집한다. 반환값은 쓰지 않지만
                // catalog가 내부에 쌓고, 그 결과가 마법사 후보와 실효 맵이 된다.
                for transition in transitions {
                    _ = catalog.stage(forId: transition.fromStatusId,
                                      name: transition.event.fromStatus)
                    _ = catalog.stage(forId: transition.toStatusId,
                                      name: transition.event.toStatus)
                }

                pageEvents.append(contentsOf: transitions.map(\.event))
                pageHistoryIds.append(contentsOf: transitions.map(\.historyId))
                processed += 1
            }

            inserted += try store.appendBackfillEvents(
                pageEvents, historyIds: pageHistoryIds, fullyRestoredKeys: pageFullyRestored
            )

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
    ///
    /// - Returns: `fullyRestored`는 이 티켓의 changelog를 온전히 받았는지다. 부분 복원의
    ///   반대이며, 호출부가 이 값으로 "라이브 관측 전이를 대체해도 되는 티켓"을 가린다.
    private func resolve(
        issue: JiraIssueWithChangelog, partiallyRestored: inout [String]
    ) async throws -> (issue: JiraIssueWithChangelog, fullyRestored: Bool) {
        guard issue.changelog.isTruncated else { return (issue, true) }
        do {
            let full = try await fetchWholeChangelog(key: issue.key)
            // 보충이 짧게 와도(서버가 total보다 적게 주고 멈춤) 받은 것을 완전한 changelog인 양
            // 돌려주게 된다. 기록하지 않으면 전이 5개 중 1개로 XP가 계산되는데
            // 사용자는 이 티켓이 온전히 소급됐다고 믿는다.
            if full.isTruncated { partiallyRestored.append(issue.key) }
            return (JiraIssueWithChangelog(
                key: issue.key, createdAt: issue.createdAt,
                dueDate: issue.dueDate, changelog: full
            ), !full.isTruncated)
        } catch is CancellationError {
            // 취소는 이 티켓의 문제가 아니다. 여기서 삼키면 사용자가 중단을 눌렀는데도
            // 백필이 끝까지 돌아 run이 "정상 완료"로 닫히고, 잘린 changelog가 영구히 남는다
            // (재시도해도 historyId 중복 검사는 이미 들어간 것만 거를 뿐이다).
            throw CancellationError()
        } catch {
            // 취소를 걸러낸 뒤에도 여기에는 조직적 실패(인증 만료·레이트 리밋)가 섞여 들어와
            // 티켓 하나의 문제로 뭉개진다. 그럼에도 넓게 잡는 이유는 한 티켓의 404가
            // 3년치 백필 전체를 되돌리게 두는 편이 더 나쁘기 때문이다 —
            // 여기까지 넣은 이벤트는 유효하고 재시도는 historyId 검사 덕에 안전하다.
            // 조직적 실패를 구분해 즉시 중단하는 것은 별도 과제로 남긴다(리뷰 m3).
            partiallyRestored.append(issue.key)
            return (issue, false)
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
            // 서버가 빈 페이지를 주면 더 받을 게 없다. 이 검사가 없으면
            // total이 실제보다 큰 경우에 무한 루프가 된다.
            // 빈 페이지가 말하는 total은 반영하지 않는다 — 범위를 벗어난 startAt에
            // 0을 돌려주는 서버가 있고, 그걸 믿으면 짧게 온 보충이 완전 복원으로 보인다.
            guard !page.histories.isEmpty else { break }
            total = max(total, page.total)
            histories.append(contentsOf: page.histories)
            guard histories.count < total else { break }
            startAt = histories.count
        }

        return JiraChangelogPage(startAt: 0, maxResults: histories.count,
                                 total: max(total, histories.count), histories: histories)
    }
}
