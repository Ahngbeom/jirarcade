import Testing
import Foundation
import ArcadeCore
import JiraKit
@testable import ArcadeApp

/// 스크립트대로 응답하는 백필 소스. 어떤 토큰으로 요청받았는지 기록한다.
///
/// `ChangelogSource`의 요구사항은 격리되지 않았으므로 `@MainActor`를 붙이지 않는다.
/// `ArcadeCoreTests`의 `ScriptedChangelogSource`와 같은 방식이다.
private final class StubChangelogSource: ChangelogSource, @unchecked Sendable {
    var pages: [(issues: [JiraIssueWithChangelog], nextPageToken: String?)]
    var catalog: [JiraStatusCatalogEntry]
    private(set) var requestedTokens: [String?] = []
    /// 이 토큰을 요청받으면 던진다. 중단·실패 시나리오에 쓴다.
    /// 이중 옵셔널인 이유: "실패시키지 않음"(nil)과 "nil 토큰에서 실패"(.some(nil))가 다르다.
    var failOnToken: String??

    init(pages: [(issues: [JiraIssueWithChangelog], nextPageToken: String?)],
         catalog: [JiraStatusCatalogEntry] = []) {
        self.pages = pages
        self.catalog = catalog
    }

    func fetchPage(jql: String, pageToken: String?)
        async throws -> (issues: [JiraIssueWithChangelog], nextPageToken: String?) {
        requestedTokens.append(pageToken)
        if let failOnToken, failOnToken == pageToken { throw StubError() }
        guard !pages.isEmpty else { return ([], nil) }
        return pages.removeFirst()
    }

    func fetchIssueChangelog(key: String, startAt: Int) async throws -> JiraChangelogPage {
        JiraChangelogPage(startAt: 0, maxResults: 100, total: 0, histories: [])
    }

    func fetchStatusCatalog() async throws -> [JiraStatusCatalogEntry] { catalog }
}

/// 백필은 로그인해야 돌아간다(`client`가 있어야 소스를 만든다). 모든 테스트가
/// 이 자격증명으로 시작해 `start()`가 `.ready`/`.mappingWorkflow`까지 가게 한다.
private func signedIn() -> InMemoryCredentialStore {
    InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
}

private func backfillIssue(
    key: String, historyId: String, at: Date, author: String,
    fromId: String = "10009", from: String = "To Do",
    toId: String = "10016", to: String = "In Progress"
) -> JiraIssueWithChangelog {
    JiraIssueWithChangelog(
        // 생성 시각을 전이보다 30일 앞에 둔다 — 정체 깨우기 XP의 기준선이 되므로
        // 붙어 있으면 전진이어도 XP가 미미해 "폴백이 닿았는가"를 구분하지 못한다.
        key: key, createdAt: at.addingTimeInterval(-30 * 86_400), dueDate: nil,
        changelog: JiraChangelogPage(startAt: 0, maxResults: 10, total: 1, histories: [
            JiraChangelogHistory(
                id: historyId, createdAt: at, authorAccountId: author,
                items: [JiraChangelogItem(field: "status", fromId: fromId, fromString: from,
                                          toId: toId, toString: to)]
            )
        ])
    )
}

/// 백필이 이벤트를 실제로 저장하고 진행률을 보고한 뒤 지운다.
@MainActor
@Test func backfillStoresEventsAndClearsProgress() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = StubChangelogSource(pages: [
        ([backfillIssue(key: "MPT-1", historyId: "1",
                        at: iso("2026-08-01T00:00:00Z"), author: "acc-me")], nil)
    ])
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: [
        "To Do": .backlog, "In Progress": .active,
    ]))
    let model = try makeModel(store: store, changelogSource: source,
                              credentials: signedIn(), workflow: workflow)
    await model.start()

    await model.startBackfill()

    // throwing 호출을 매크로 밖으로 뺀다 — `#expect(try ...)`는 클로저가 non-throwing으로
    // 추론돼 경고가 난다.
    let events = try store.loadEvents()
    #expect(events.count == 1, "백필이 이벤트를 넣어야 한다")
    #expect(model.backfillProgress == nil, "끝나면 진행 바가 사라진다")
    #expect(model.hasResumableBackfill == false, "정상 종료된 백필은 재개 대상이 아니다")
}

/// **이 배선의 존재 이유.** 매핑에 없는 상태가 폴백으로 해석돼 저장되고,
/// 그 덕에 XP가 0이 아니게 된다.
@MainActor
@Test func fallbackMappingIsStoredAndReachesScoring() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    // "Merged to Staging"은 사용자 매핑에 없다. 카탈로그의 statusCategory로만 해석된다.
    let source = StubChangelogSource(
        pages: [([backfillIssue(key: "MPT-1", historyId: "1",
                                at: iso("2026-08-01T00:00:00Z"), author: "acc-me",
                                fromId: "10009", from: "To Do",
                                toId: "10071", to: "Merged to Staging")], nil)],
        catalog: [
            JiraStatusCatalogEntry(id: "10009", name: "To Do", categoryKey: "new"),
            JiraStatusCatalogEntry(id: "10071", name: "Merged to Staging",
                                   categoryKey: "indeterminate"),
        ]
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let model = try makeModel(store: store, changelogSource: source,
                              credentials: signedIn(), workflow: workflow)
    await model.start()

    await model.startBackfill()

    let fallbacks = try workflow.loadFallbacks()
    #expect(fallbacks?.statusToStage == ["Merged to Staging": .active],
            "폴백 매핑이 저장돼야 다음 재집계에서도 쓸 수 있다")
    let lifetime = try #require(model.lifetimeSummary)
    #expect(lifetime.totalXP > 0,
            "backlog -> active 전진이므로 폴백이 채점에 닿았다면 XP가 붙는다")
}

/// 저장된 폴백은 덮이지 않고 쌓인다. 덮어쓰면 이전 실행이 해석한 매핑이 사라진다.
@MainActor
@Test func newFallbacksMergeWithStoredOnes() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    try workflow.saveFallbacks(WorkflowMap(statusToStage: ["QA Passed": .verify]))

    let source = StubChangelogSource(
        pages: [([backfillIssue(key: "MPT-1", historyId: "1",
                                at: iso("2026-08-01T00:00:00Z"), author: "acc-me",
                                toId: "10071", to: "Merged to Staging")], nil)],
        catalog: [JiraStatusCatalogEntry(id: "10071", name: "Merged to Staging",
                                         categoryKey: "indeterminate")]
    )
    let model = try makeModel(store: store, changelogSource: source,
                              credentials: signedIn(), workflow: workflow)
    await model.start()

    await model.startBackfill()

    let stored = try #require(try workflow.loadFallbacks()).statusToStage
    #expect(stored["QA Passed"] == .verify, "이전 폴백이 살아 있어야 한다")
    #expect(stored["Merged to Staging"] == .active)
}

/// 사용자 매핑이 폴백을 이긴다 — 마법사에서 지정한 값이 추정값에 덮이면 안 된다.
@MainActor
@Test func userMappingWinsOverStoredFallbackWhenScoring() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let event = DomainEvent(
        issueKey: "MPT-1", kind: .statusChanged,
        fromStatus: "In Progress", toStatus: "Merged to Staging",
        observedAt: iso("2026-08-10T00:00:00Z"), actorAccountId: "acc-me",
        priorUpdatedAt: iso("2026-08-01T00:00:00Z")
    )
    _ = try store.appendBackfillEvents([event], historyIds: ["h-1"])

    // 사용자는 review로 지정했는데 폴백은 active로 추정했다.
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: [
        "In Progress": .active, "Merged to Staging": .review,
    ]))
    try workflow.saveFallbacks(WorkflowMap(statusToStage: ["Merged to Staging": .active]))

    let model = try makeModel(store: store, credentials: signedIn(), workflow: workflow)
    await model.start()

    // 사용자 매핑(review, order 2)이 이기면 active(order 1)에서의 전진이라 XP가 붙는다.
    // 폴백이 이기면 active -> active 수평 이동이라 0점이다.
    let lifetime = try #require(model.lifetimeSummary)
    #expect(lifetime.totalXP > 0, "사용자 매핑이 이겨야 전진으로 채점된다")
}

/// 중단해도 이미 넣은 이벤트는 남고, 재개 지점이 저장돼 "이어서"가 뜬다.
/// 롤백하지 않는 것이 설계다 — 이벤트 로그는 append-only다(스펙 §7.2).
@MainActor
@Test func failureKeepsStoredEventsAndLeavesAResumePoint() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = StubChangelogSource(pages: [
        ([backfillIssue(key: "MPT-1", historyId: "1",
                        at: iso("2026-08-01T00:00:00Z"), author: "acc-me")], "tok-2"),
    ])
    source.failOnToken = .some("tok-2")   // 두 번째 페이지에서 실패
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: [
        "To Do": .backlog, "In Progress": .active,
    ]))
    let model = try makeModel(store: store, changelogSource: source,
                              credentials: signedIn(), workflow: workflow)
    await model.start()

    await model.startBackfill()

    let events = try store.loadEvents()
    #expect(events.count == 1, "실패해도 첫 페이지 결과는 남는다")
    #expect(model.hasResumableBackfill, "중단 지점이 남아 이어받을 수 있어야 한다")
    let snapshot = try #require(try store.resumableBackfill())
    #expect(snapshot.nextPageToken == "tok-2")
}

/// 재개는 저장된 토큰부터 요청한다. 처음부터 다시 훑으면 왕복 시간이 통째로 낭비된다.
@MainActor
@Test func resumeRequestsTheStoredToken() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let runId = try store.beginBackfill(jql: "assignee = currentUser()",
                                        at: iso("2026-08-13T00:00:00Z"), totalIssueCount: 200)
    try store.advanceBackfill(runId, nextPageToken: "tok-9", processedIssueCount: 100,
                              discovered: [], partiallyRestored: [])

    let source = StubChangelogSource(pages: [([], nil)])
    let model = try makeModel(store: store, changelogSource: source, credentials: signedIn())
    await model.start()

    await model.resumeBackfillIfAvailable()

    #expect(source.requestedTokens == ["tok-9"])
}

/// 재개할 것이 없으면 아무 일도 하지 않는다 — 요청조차 나가지 않아야 한다.
@MainActor
@Test func resumeWithNothingStoredDoesNothing() async throws {
    let source = StubChangelogSource(pages: [([], nil)])
    let model = try makeModel(changelogSource: source, credentials: signedIn())
    await model.start()

    await model.resumeBackfillIfAvailable()

    #expect(source.requestedTokens.isEmpty)
}

/// 백필이 돌고 있으면 두 번째 시작은 무시된다 — 같은 페이지를 두 곳에서 훑으면
/// 진행률 카운터가 뒤엉킨다(이벤트 중복은 historyId가 막지만 카운터는 못 막는다).
@MainActor
@Test func startingTwiceRunsOnlyOnce() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = StubChangelogSource(pages: [
        ([backfillIssue(key: "MPT-1", historyId: "1",
                        at: iso("2026-08-01T00:00:00Z"), author: "acc-me")], nil)
    ])
    let model = try makeModel(store: store, changelogSource: source, credentials: signedIn())
    await model.start()

    async let first: Void = model.startBackfill()
    async let second: Void = model.startBackfill()
    _ = await (first, second)

    #expect(source.requestedTokens.count == 1, "페이지 요청이 한 번만 나가야 한다")
}

/// 시즌은 통산의 부분집합이다. 시즌 밖 이벤트가 있으면 시즌 XP는 통산보다 **엄격히** 작아야
/// 한다 — `<=`로 검사하면 둘 다 0일 때도 통과해 아무것도 검증하지 못한다(스펙 §6).
@MainActor
@Test func seasonSummaryIsStrictlySmallerWhenOldEventsExist() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let now = iso("2026-08-14T09:00:00Z")
    let old = DomainEvent(
        issueKey: "MPT-1", kind: .statusChanged, fromStatus: "To Do", toStatus: "In Progress",
        observedAt: iso("2026-01-05T00:00:00Z"), actorAccountId: "acc-me",
        priorUpdatedAt: iso("2025-12-15T00:00:00Z")
    )
    let recent = DomainEvent(
        issueKey: "MPT-2", kind: .statusChanged, fromStatus: "To Do", toStatus: "In Progress",
        observedAt: iso("2026-08-10T00:00:00Z"), actorAccountId: "acc-me",
        priorUpdatedAt: iso("2026-07-20T00:00:00Z")
    )
    _ = try store.appendBackfillEvents([old, recent], historyIds: ["h-old", "h-recent"])

    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: [
        "To Do": .backlog, "In Progress": .active,
    ]))
    let model = try makeModel(store: store, credentials: signedIn(),
                              workflow: workflow, now: now)

    await model.start()

    let lifetime = try #require(model.lifetimeSummary)
    let season = try #require(model.seasonSummary)
    #expect(lifetime.totalXP > 0, "이벤트가 있으므로 통산 XP가 0이면 집계가 안 된 것이다")
    #expect(season.totalXP > 0, "시즌 안 이벤트가 있으므로 시즌 XP도 0이 아니다")
    #expect(season.totalXP < lifetime.totalXP, "시즌 밖 이벤트가 통산에만 잡혀야 한다")
}
