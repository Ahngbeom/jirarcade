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
    /// 상태 카탈로그 조회를 실패시킨다. 폴백 ②가 꺼진 채로 도는 시나리오에 쓴다.
    var catalogError: (any Error)?

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

    func fetchStatusCatalog() async throws -> [JiraStatusCatalogEntry] {
        if let catalogError { throw catalogError }
        return catalog
    }
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

/// 실패 사유가 모델까지 오고, 앱을 다시 켜도 남는다. 설정 화면이 "이어서 불러오기" 옆에
/// 왜 중단됐는지 적을 수 있는 유일한 근거다 — 스토어에만 있고 모델이 읽지 않으면
/// 사용자는 재개 버튼이 왜 떠 있는지 알 수 없다.
@MainActor
@Test func failureReasonReachesTheModelAndSurvivesRelaunch() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = StubChangelogSource(pages: [
        ([backfillIssue(key: "MPT-1", historyId: "1",
                        at: iso("2026-08-01T00:00:00Z"), author: "acc-me")], "tok-2"),
    ])
    source.failOnToken = .some("tok-2")
    let model = try makeModel(store: store, changelogSource: source, credentials: signedIn())
    await model.start()

    await model.startBackfill()

    // 타입 이름만 담긴다 — 호스트·JQL·토큰 조각이 새면 안 된다(BackfillEngine.failureDescription).
    #expect(model.lastBackfillFailure == "StubError")

    let relaunched = try makeModel(store: store, credentials: signedIn())
    await relaunched.start()
    #expect(relaunched.lastBackfillFailure == "StubError",
            "다시 켰을 때도 중단 사유가 보여야 한다")
}

/// 카탈로그를 못 받은 실행은 정확도가 낮다고 표시되고, 카탈로그를 받은 실행이 성공하면
/// 표시가 걷힌다. 그 사이의 **실패한** 실행은 결론을 덮지 않는다 — 실패한 실행에는
/// "카탈로그를 받았는가"에 대한 결론 자체가 없기 때문이다.
@MainActor
@Test func degradedFlagIsSetOnlyBySuccessfulRuns() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = StubChangelogSource(pages: [
        ([backfillIssue(key: "MPT-1", historyId: "1",
                        at: iso("2026-08-01T00:00:00Z"), author: "acc-me")], nil)
    ])
    source.catalogError = StubError()
    let model = try makeModel(store: store, changelogSource: source, credentials: signedIn())
    await model.start()

    await model.startBackfill()
    #expect(model.backfillWasDegraded, "카탈로그를 못 받았으면 폴백 ②가 꺼진 채로 돈 것이다")

    // 실패한 실행이 경고를 걷어가면 안 된다.
    source.pages = [([], nil)]
    source.failOnToken = .some(nil)
    await model.startBackfill()
    #expect(model.backfillWasDegraded, "실패한 실행의 값으로 이전 결론을 덮지 않는다")

    // 카탈로그를 받은 성공 실행만 경고를 걷는다.
    source.failOnToken = nil
    source.catalogError = nil
    source.pages = [([], nil)]
    await model.startBackfill()
    #expect(model.backfillWasDegraded == false, "카탈로그를 받은 성공 실행이면 경고가 걷힌다")
    #expect(model.lastBackfillFailure == nil, "성공한 실행 뒤에는 실패 사유가 남지 않는다")
}

/// 백필이 발견한 과거 상태가 앱을 다시 켜도 남아 매핑 후보로 올라온다.
/// 사용자가 확정하면 재집계로 소급 XP가 정확해진다 — 이벤트가 원본이고 점수는 파생이다(스펙 §5).
@MainActor
@Test func historyDiscoveredStatusesRestoreOnLaunch() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let runId = try store.beginBackfill(jql: "q", at: iso("2026-08-13T09:00:00Z"),
                                        totalIssueCount: 100)
    try store.advanceBackfill(runId, nextPageToken: "tok", processedIssueCount: 40,
                              discovered: ["Merged to Staging", "QA Done"], partiallyRestored: [])

    let model = try makeModel(store: store, credentials: signedIn())

    await model.start()

    #expect(Set(model.historyDiscoveredStatuses) == ["Merged to Staging", "QA Done"])
    #expect(model.hasResumableBackfill == true, "중단된 백필이 있으면 이어받기를 제안해야 한다")
}

/// **정상 종료된** 백필의 발견 목록도 남아야 한다. `resumableBackfill()`은 미완료 run만
/// 보므로 그것만 읽으면 백필이 끝나는 순간 매핑 후보가 통째로 사라진다 —
/// 정작 매핑이 필요한 시점은 백필이 끝난 뒤다.
@MainActor
@Test func discoveriesSurviveAFinishedBackfill() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let runId = try store.beginBackfill(jql: "q", at: iso("2026-08-13T09:00:00Z"),
                                        totalIssueCount: 100)
    try store.advanceBackfill(runId, nextPageToken: nil, processedIssueCount: 100,
                              discovered: ["Merged to Staging"], partiallyRestored: [])
    try store.finishBackfill(runId, at: iso("2026-08-13T09:30:00Z"), failure: nil)

    let model = try makeModel(store: store, credentials: signedIn())
    await model.start()

    #expect(model.historyDiscoveredStatuses == ["Merged to Staging"])
    #expect(model.hasResumableBackfill == false, "끝난 백필은 이어받기 대상이 아니다")
}

/// 로그아웃이 백필에서 나온 값들을 지운다. 남으면 다른 계정으로 로그인했을 때 이전 조직의
/// 상태명이 새 계정의 매핑 후보로 뜬다 — 조직이 다르면 완전히 무의미한 목록이다.
/// `ArcadeStore.reset()`이 `BackfillRun`을 지우는 것과 같은 이유다.
@MainActor
@Test func signOutClearsHistoryDiscoveriesAndDegradedWarning() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    // 카탈로그를 못 받으면 매핑에 없는 상태는 전부 ③ 미매핑으로 수집된다 —
    // 발견 목록과 정확도 경고를 한 번에 세우는 가장 짧은 경로다.
    let source = StubChangelogSource(pages: [
        ([backfillIssue(key: "MPT-1", historyId: "1",
                        at: iso("2026-08-01T00:00:00Z"), author: "acc-me",
                        toId: "10071", to: "Merged to Staging")], nil)
    ])
    source.catalogError = StubError()
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let model = try makeModel(store: store, changelogSource: source,
                              credentials: signedIn(), workflow: workflow)
    await model.start()
    await model.startBackfill()

    #expect(model.historyDiscoveredStatuses == ["Merged to Staging"],
            "이 테스트가 무엇을 지우는지 검증하려면 먼저 값이 서 있어야 한다")
    #expect(model.backfillWasDegraded, "카탈로그를 못 받았으므로 정확도 경고가 서 있어야 한다")

    await model.signOut()

    #expect(model.historyDiscoveredStatuses.isEmpty,
            "이전 계정의 상태명이 새 계정의 매핑 후보로 뜨면 안 된다")
    #expect(model.backfillWasDegraded == false,
            "정확도 경고는 이전 계정의 백필에 대한 결론이다")
}

/// 실패 사유도 로그아웃에서 지워진다. 스토어에서 다시 읽는 값이지만, 다음 로그인이
/// 성공하기 전까지는 이전 계정의 사유가 모델에 남는다.
@MainActor
@Test func signOutClearsLastBackfillFailure() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let runId = try store.beginBackfill(jql: "q", at: iso("2026-08-13T09:00:00Z"),
                                        totalIssueCount: 100)
    try store.recordBackfillFailure(runId, message: "StubError")
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let model = try makeModel(store: store, credentials: signedIn(), workflow: workflow)
    await model.start()
    #expect(model.lastBackfillFailure == "StubError")

    await model.signOut()

    #expect(model.lastBackfillFailure == nil, "이전 계정의 중단 사유를 새 계정에 보여주면 안 된다")
}

// MARK: - 매핑 재진입과 백필 재시작

/// 매핑을 끝낸 뒤에도 마법사로 돌아갈 수 있어야 한다. 그러지 못하면 백필이 발견한
/// 과거 상태를 사용자가 영영 고칠 수 없다 — 폴백이 방향까지 틀린 경우가 실물에서 나왔다.
@MainActor
@Test func mappingCanBeReopenedAfterItIsConfirmed() async throws {
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["Done": .done]))
    let model = try makeModel(credentials: signedIn(), workflow: workflow)
    await model.start()
    #expect(model.phase == .ready)

    await model.reopenMapping()

    guard case .mappingWorkflow = model.phase else {
        Issue.record("마법사로 돌아가야 한다: \(model.phase)")
        return
    }
}

/// 후보 조회가 실패해도 마법사는 열려야 한다. 과거 이력에서 발견한 상태만으로도
/// 고칠 것이 있고, 애초에 고쳐야 할 것은 지금 티켓이 아니라 그 목록이다.
/// (기본 스텁 HTTP는 응답을 하나만 들고 있어 `myself()`에서 소진된다 —
///  그래서 뒤이은 후보 조회는 자연히 실패한다.)
@MainActor
@Test func reopeningMappingSurvivesACandidateLookupFailure() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let runId = try store.beginBackfill(jql: "q", at: iso("2026-08-13T09:00:00Z"),
                                        totalIssueCount: 10)
    try store.advanceBackfill(runId, nextPageToken: nil, processedIssueCount: 10,
                              discovered: ["Merged to Staging"], partiallyRestored: [])
    try store.finishBackfill(runId, at: iso("2026-08-13T09:30:00Z"), failure: nil)
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["Done": .done]))
    let model = try makeModel(store: store, credentials: signedIn(), workflow: workflow)
    await model.start()

    await model.reopenMapping()

    guard case .mappingWorkflow(let candidates) = model.phase else {
        Issue.record("조회가 실패해도 마법사는 열려야 한다: \(model.phase)")
        return
    }
    #expect(candidates.isEmpty, "조회가 실패했으므로 현재 티켓에서 온 후보는 없다")
    #expect(model.historyDiscoveredStatuses == ["Merged to Staging"],
            "마법사가 후보에 더할 과거 발견 목록은 그대로 남아 있어야 한다")
}

/// 다시 연 마법사는 **기존 매핑을 초기값으로** 들고 있어야 한다.
/// 빈 화면으로 시작하면 확정하는 순간 이미 설정한 매핑이 통째로 사라진다.
@MainActor
@Test func reopenedMappingCarriesTheExistingSelection() async throws {
    let existing = WorkflowMap(statusToStage: ["Done": .done, "To Do": .backlog])
    let workflow = InMemoryWorkflowStore(seeded: existing)
    let model = try makeModel(credentials: signedIn(), workflow: workflow)
    await model.start()

    await model.reopenMapping()

    #expect(model.currentMapping.statusToStage == existing.statusToStage)
}

/// `currentMapping`을 노출하는 것만으로는 부족하다 — 마법사가 그 값을 실제로 초기값으로
/// 집어야 데이터가 보존된다. 그 배선은 SwiftUI 뷰 안에 있고 ArcadeUI에는 테스트 타깃이
/// 없으므로, `ModuleBoundaryTests`가 색 리터럴을 잡는 것과 같은 방식으로 소스를 읽어 지킨다.
/// 이 줄이 빠지면 "매핑 수정하기"가 조용히 기존 매핑을 지우는 버튼이 된다.
@Test func theMappingWizardSeedsItsSelectionFromTheStoredMap() throws {
    let view = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ArcadeAppTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // 패키지 루트
        .appendingPathComponent("Sources/ArcadeUI/WorkflowMappingView.swift")
    let text = try String(contentsOf: view, encoding: .utf8)

    // 결과를 먼저 Bool로 받는다 — `#expect(text.contains(...))`로 쓰면 실패 메시지가
    // 파일 전체를 쏟아내 무엇이 틀렸는지 읽을 수 없다.
    let seedsFromStoredMap = text.contains("State(initialValue: model.currentMapping.statusToStage)")
    #expect(seedsFromStoredMap,
            "마법사가 기존 매핑을 초기값으로 집지 않으면 확정하는 순간 매핑이 덮어써진다")
}

/// 처음부터 다시 훑는 경로가 있어야 한다. 이어받기는 1회차에 놓친 티켓을 다시 보지 않으므로
/// 카탈로그 실패로 떨어진 정확도를 회복할 방법이 그것뿐이다.
@MainActor
@Test func restartingBackfillIgnoresTheResumePoint() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let runId = try store.beginBackfill(jql: "assignee = currentUser()",
                                        at: iso("2026-08-13T00:00:00Z"), totalIssueCount: 200)
    try store.advanceBackfill(runId, nextPageToken: "tok-9", processedIssueCount: 100,
                              discovered: [], partiallyRestored: [])

    let source = StubChangelogSource(pages: [([], nil)])
    let model = try makeModel(store: store, changelogSource: source, credentials: signedIn())
    await model.start()

    await model.startBackfill()   // 재개가 아니라 처음부터

    #expect(source.requestedTokens == [nil], "저장된 커서를 무시하고 처음부터 훑는다")
    #expect(model.hasResumableBackfill == false, "재시작이 이전 재개 지점도 정리한다")
}

/// 로그아웃은 백필 관련 파생 상태를 남기지 않는다. 계정이 바뀌면 이전 조직의
/// 상태명과 진행 상황이 새 계정 화면에 뜬다.
@MainActor
@Test func signOutClearsEveryBackfillDerivedValue() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let runId = try store.beginBackfill(jql: "q", at: iso("2026-08-13T00:00:00Z"),
                                        totalIssueCount: 10)
    try store.advanceBackfill(runId, nextPageToken: "tok", processedIssueCount: 5,
                              discovered: ["Merged to Staging"], partiallyRestored: [])
    let model = try makeModel(store: store, credentials: signedIn())
    await model.start()
    #expect(model.hasResumableBackfill)

    await model.signOut()

    #expect(model.historyDiscoveredStatuses.isEmpty)
    #expect(model.hasResumableBackfill == false)
    #expect(model.lastBackfillFailure == nil)
    #expect(model.backfillWasDegraded == false)
}
