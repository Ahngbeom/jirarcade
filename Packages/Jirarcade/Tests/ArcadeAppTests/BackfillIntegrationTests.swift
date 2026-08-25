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
        await onFetchPage?(pageToken)
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

    /// 진행률 총계. 기본값 nil은 "서버가 답하지 못했다"이며 던진다 —
    /// 총계 조회 실패는 백필을 막지 않아야 하므로 이쪽이 더 엄한 기본값이다.
    var approximateCount: Int?

    func approximateIssueCount(jql: String) async throws -> Int {
        guard let approximateCount else { throw StubError() }
        return approximateCount
    }

    /// 페이지를 요청받는 순간 부른다. 백필이 도는 **도중의** 상태를 검사하거나
    /// 그 시점에 중단을 거는 자리다.
    var onFetchPage: (@Sendable (String?) async -> Void)?
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
    _ = try store.appendBackfillEvents([event], historyIds: ["h-1"], fullyRestoredKeys: [])

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
    _ = try store.appendBackfillEvents([old, recent], historyIds: ["h-old", "h-recent"],
                                       fullyRestoredKeys: [])

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

/// 카탈로그를 못 받은 채 **실패로 끝난** 실행도 정확도 경고를 남긴다.
///
/// 예전에는 경고가 성공 경로에서만 대입되는 메모리 값이라 이 경우 통째로 사라졌다.
/// 하필 카탈로그 조회가 실패하는 상황이면 네트워크가 불안정해 페이지 조회도 실패하기 쉽다 —
/// degradation이 가장 잘 일어나는 조건에서 경고가 가장 잘 사라졌다는 뜻이다.
@MainActor
@Test func degradedWarningSurvivesARunThatFailed() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = StubChangelogSource(pages: [([], nil)])
    source.catalogError = StubError()
    source.failOnToken = .some(nil)   // 첫 페이지부터 실패한다
    let model = try makeModel(store: store, changelogSource: source, credentials: signedIn())
    await model.start()

    await model.startBackfill()

    #expect(model.lastBackfillFailure == "StubError", "실패로 끝난 실행이어야 이 테스트가 성립한다")
    #expect(model.backfillWasDegraded,
            "실패로 끝났어도 카탈로그를 못 받았다는 사실은 그대로다")
}

/// 정확도 경고는 앱을 다시 켜도 남는다. 메모리에만 있으면 사용자는 다음 실행에서
/// 자기 XP가 왜 적은지 알 방법이 없다 — 설정 화면은 아무 말도 하지 않는다.
@MainActor
@Test func degradedWarningSurvivesRelaunch() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = StubChangelogSource(pages: [
        ([backfillIssue(key: "MPT-1", historyId: "1",
                        at: iso("2026-08-01T00:00:00Z"), author: "acc-me")], nil)
    ])
    source.catalogError = StubError()
    let model = try makeModel(store: store, changelogSource: source, credentials: signedIn())
    await model.start()
    await model.startBackfill()
    #expect(model.backfillWasDegraded)

    let relaunched = try makeModel(store: store, credentials: signedIn())
    await relaunched.start()

    #expect(relaunched.backfillWasDegraded, "다시 켰을 때도 정확도 경고가 보여야 한다")
}

/// 카탈로그가 살아난 **이어받기**가 성공해도 경고는 남는다.
///
/// 폴백은 그 walk에서 실제로 본 전이만 해석한다 — 1회차에 카탈로그 없이 지나간 티켓은
/// 이어받기로도 다시 해석되지 않는다. 2회차만 보고 경고를 걷으면 사용자는 정확도가
/// 회복됐다고 믿는다. 회복하는 길은 처음부터 다시 훑는 것뿐이다.
@MainActor
@Test func resumeKeepsTheDegradedWarningFromTheFirstPass() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = StubChangelogSource(pages: [
        ([backfillIssue(key: "MPT-1", historyId: "1",
                        at: iso("2026-08-01T00:00:00Z"), author: "acc-me")], "tok-2"),
    ])
    source.catalogError = StubError()
    source.failOnToken = .some("tok-2")
    let model = try makeModel(store: store, changelogSource: source, credentials: signedIn())
    await model.start()
    await model.startBackfill()
    #expect(model.backfillWasDegraded, "1회차가 카탈로그 없이 돌았다")

    // 2회차는 카탈로그를 받아 정상 종료한다.
    source.catalogError = nil
    source.failOnToken = nil
    source.pages = [([], nil)]
    await model.resumeBackfillIfAvailable()

    #expect(model.hasResumableBackfill == false, "이어받기가 정상 종료했다")
    #expect(model.backfillWasDegraded,
            "1회차에 지나간 티켓은 이어받기로 다시 해석되지 않는다")
}

/// **처음부터 다시** 훑은 실행이 카탈로그를 받았으면 경고가 걷힌다. 누적 플래그가
/// run 단위라는 것을 고정한다 — 영원히 켜져 있으면 알림으로서 의미가 없다.
///
/// 두 run의 `startedAt`이 달라야 한다(스토어의 "마지막 run" 조회가 그 값으로 정렬한다).
/// 실제로도 한 순간에 두 번 시작할 수는 없으므로, 앱을 다시 켠 상황으로 재현한다.
@MainActor
@Test func aFreshRunWithTheCatalogClearsTheDegradedWarning() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = StubChangelogSource(pages: [
        ([backfillIssue(key: "MPT-1", historyId: "1",
                        at: iso("2026-08-01T00:00:00Z"), author: "acc-me")], nil)
    ])
    source.catalogError = StubError()
    let degraded = try makeModel(store: store, changelogSource: source, credentials: signedIn(),
                                 now: iso("2026-08-14T09:00:00Z"))
    await degraded.start()
    await degraded.startBackfill()
    #expect(degraded.backfillWasDegraded)

    source.catalogError = nil
    source.pages = [([], nil)]
    let later = try makeModel(store: store, changelogSource: source, credentials: signedIn(),
                              now: iso("2026-08-14T10:00:00Z"))
    await later.start()
    await later.startBackfill()

    #expect(later.backfillWasDegraded == false, "카탈로그를 받은 새 실행이면 경고가 걷힌다")
    #expect(later.lastBackfillFailure == nil, "성공한 실행 뒤에는 실패 사유가 남지 않는다")
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

/// 이어받은 뒤 스스로 중단하면 **옛 실패 사유가 남아 있으면 안 된다.**
///
/// 순서가 중요하다 — 실패 → 이어받기 → 중단이어야 한다. 첫 실행의 중단은 `beginBackfill`이
/// 새 행을 만들어 정상 동작하므로 그 경로만 보면 이 결함을 놓친다. 이어받기는 **같은 run
/// 행을 재사용**하는데 취소는 사유를 적지 않으므로(의도된 동작), 지우지 않으면 사용자가
/// 방금 스스로 중단한 직후에 앱이 "지난 불러오기가 중단되었습니다 (StubError)"라고 말한다.
@MainActor
@Test func resumingThenCancellingDoesNotShowTheOldFailure() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = StubChangelogSource(pages: [
        ([backfillIssue(key: "MPT-1", historyId: "1",
                        at: iso("2026-08-01T00:00:00Z"), author: "acc-me")], "tok-2"),
    ])
    source.failOnToken = .some("tok-2")
    let model = try makeModel(store: store, changelogSource: source, credentials: signedIn())
    await model.start()
    await model.startBackfill()
    #expect(model.lastBackfillFailure == "StubError",
            "실패가 먼저 기록돼야 이 테스트가 무언가를 검증한다")

    // 이어받기. 저장된 토큰을 받는 순간 사용자가 "중단"을 누른다 — 취소는 페이지 경계에서
    // 걸리므로 이어받은 walk가 페이지를 하나 더 요청하려 할 때 빠져나온다.
    source.failOnToken = nil
    source.pages = [([], "tok-3"), ([], nil)]
    source.onFetchPage = { token in
        guard token == "tok-2" else { return }
        await MainActor.run { model.cancelBackfill() }
    }

    await model.resumeBackfillIfAvailable()

    #expect(source.requestedTokens.contains("tok-2"), "이어받기가 실제로 돌았는지 확인한다")
    #expect(model.hasResumableBackfill, "중단은 재개 지점을 남긴다")
    #expect(model.lastBackfillFailure == nil,
            "스스로 중단한 사용자에게 지난 실패 문구를 보여주면 안 된다")
}

/// 버튼을 누른 즉시 "실행 중"이어야 한다. 진행률은 첫 페이지를 다 처리한 뒤에야 오는데,
/// 그 전에 총계 조회 + 카탈로그 조회 + 첫 페이지 조회가 있어 실측에서 수십 초였다.
/// 그동안 화면이 시작 버튼을 활성 상태로 두면 사용자에게는 버튼이 먹지 않은 것처럼 보인다.
@MainActor
@Test func backfillShowsAsRunningBeforeTheFirstPageArrives() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = StubChangelogSource(pages: [
        ([backfillIssue(key: "MPT-1", historyId: "1",
                        at: iso("2026-08-01T00:00:00Z"), author: "acc-me")], nil)
    ])
    let model = try makeModel(store: store, changelogSource: source, credentials: signedIn())
    await model.start()
    #expect(model.isBackfilling == false, "시작 전에는 실행 중이 아니다")

    source.onFetchPage = { _ in
        await MainActor.run {
            #expect(model.isBackfilling, "첫 페이지를 받기도 전에 이미 실행 중이어야 한다")
            #expect(model.backfillProgress == nil,
                    "진행률은 아직 없다 — 바로 이 구간이 검사 대상이다")
        }
    }

    await model.startBackfill()

    // 훅이 돌지 않으면 위 검사는 한 번도 실행되지 않고 조용히 통과한다.
    #expect(source.requestedTokens.count == 1, "페이지 조회가 실제로 일어났다")
    #expect(model.isBackfilling == false, "끝나면 실행 중 표시가 내려간다")
}

/// 마법사에서 확인만 눌러도 추정값이 사용자 매핑으로 **승격되면 안 된다.**
/// 한 번 승격되면 사용자 매핑이 항상 위에 얹히므로(`effectiveWorkflow`),
/// 이후 폴백이 더 정확해져도 영영 이기지 못한다.
@MainActor
@Test func confirmingMappingDoesNotPromoteFallbacksToUserMapping() async throws {
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    try workflow.saveFallbacks(WorkflowMap(statusToStage: ["Merged to Staging": .done]))
    let model = try makeModel(credentials: signedIn(), workflow: workflow)
    await model.start()

    #expect(model.currentFallbacks.stage(for: "Merged to Staging") == .done,
            "마법사가 '지금은 완료로 추정해 채점 중'이라고 적을 근거가 모델에 있어야 한다")

    // 사용자가 아무것도 고르지 않고 확인만 눌렀다.
    await model.confirmMapping(model.currentMapping)

    let saved = try #require(try workflow.load())
    #expect(saved.stage(for: "Merged to Staging") == nil, "추정값은 사용자 매핑이 아니다")
    #expect(model.currentFallbacks.stage(for: "Merged to Staging") == .done,
            "폴백은 그대로 밑에 깔린 채 남는다")
}

/// 매핑을 고치면 **그 자리에서** 점수가 다시 계산된다. 재집계를 걸지 않으면
/// 사용자가 잘못된 추정을 바로잡아도 XP·레벨이 그대로여서 아무 일도 일어나지 않은 것처럼
/// 보인다. 동기화 완료를 기다리지 않고 저장된 이벤트로 바로 돌아야 즉시 반영된다.
@MainActor
@Test func fixingTheMappingRecomputesRightAway() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let event = DomainEvent(
        issueKey: "MPT-1", kind: .statusChanged,
        fromStatus: "In Progress", toStatus: "Merged to Staging",
        observedAt: iso("2026-08-10T00:00:00Z"), actorAccountId: "acc-me",
        priorUpdatedAt: iso("2026-08-01T00:00:00Z")
    )
    _ = try store.appendBackfillEvents([event], historyIds: ["h-1"], fullyRestoredKeys: [])
    let workflow = InMemoryWorkflowStore(
        seeded: WorkflowMap(statusToStage: ["In Progress": .active])
    )
    try workflow.saveFallbacks(WorkflowMap(statusToStage: ["Merged to Staging": .active]))
    let model = try makeModel(store: store, credentials: signedIn(), workflow: workflow)
    await model.start()

    let before = try #require(model.lifetimeSummary)
    #expect(before.totalXP == 0, "폴백대로면 active -> active 수평 이동이라 0점이다")

    await model.confirmMapping(WorkflowMap(statusToStage: [
        "In Progress": .active, "Merged to Staging": .review,
    ]))

    let after = try #require(model.lifetimeSummary)
    #expect(after.totalXP > 0, "전진으로 다시 채점돼 XP가 붙어야 한다")
}

// MARK: - 화면 배선

/// 캐비닛과 HUD가 **같은** 통산 요약을 읽는지 소스로 확인한다. 예전에는 동기화 경로가
/// 따로 담은 값을 캐비닛이 읽어, 백필 직후부터 다음 동기화까지 한 화면에
/// "LV.1 · 2,340 XP"(캐비닛)와 "통산 LV.50"(HUD)이 나란히 떴다.
///
/// ArcadeUI에는 테스트 타깃이 없으므로 `ModuleBoundaryTests`가 색 리터럴을 잡는 것과
/// 같은 방식으로 소스를 읽는다.
@Test func theCabinetReadsTheSameLifetimeSummaryAsTheHud() throws {
    let text = try uiSource("ObservationCabinet.swift")

    let usesLifetime = text.contains("model.lifetimeSummary")
    let usesSyncOnlySummary = text.contains("model.summary")
    #expect(usesLifetime, "캐비닛은 HUD와 같은 통산 요약을 읽어야 한다")
    #expect(!usesSyncOnlySummary, "동기화 경로가 따로 담은 값을 읽으면 두 값이 어긋난다")

    // "아직 동기화 전"은 집계값이 아니라 lastSync로 판정해야 한다 — 집계값은 첫 동기화
    // 전에도 백필이 넣은 이벤트로 채워지므로, 그것으로 판정하면 안내가 영영 안 뜬다.
    let gatesOnLastSync = text.contains("model.lastSync == nil")
    #expect(gatesOnLastSync, "'아직 동기화 전'은 lastSync로 판정해야 한다")
}

/// 설정 화면이 "실행 중"을 진행률이 아니라 실행 태스크로 판정하는지 확인한다.
/// 진행률로 판정하면 시작 직후 수십 초 동안 버튼이 먹지 않은 것처럼 보인다.
@Test func settingsDecidesRunningStateFromTheTask() throws {
    let text = try uiSource("SettingsView.swift")
    let gatesOnIsBackfilling = text.contains("if model.isBackfilling")
    #expect(gatesOnIsBackfilling, "설정 화면은 isBackfilling으로 실행 중을 판정해야 한다")
}

/// 마법사가 행마다 현재 추정을 보여주는지 확인한다. 이 표시가 없으면 설정 화면의
/// "상태 N개가 추정값으로 채점되고 있습니다"는 개수만 알려줄 뿐, 사용자는 무엇을
/// 고쳐야 하는지 알 수 없다.
@Test func theMappingWizardShowsTheCurrentGuessPerRow() throws {
    let text = try uiSource("WorkflowMappingView.swift")
    let readsFallbacks = text.contains("model.currentFallbacks.stage(for: entry.name)")
    #expect(readsFallbacks, "행마다 지금 무엇으로 채점 중인지 보여줘야 한다")
    // 폴백을 초기 선택으로 채우면 확인만 눌러도 추정값 전부가 사용자 매핑으로 승격된다.
    let seedsOnlyFromUserMap =
        text.contains("State(initialValue: model.currentMapping.statusToStage)")
    #expect(seedsOnlyFromUserMap, "초기 선택은 사용자 매핑에서만 와야 한다")
}

private func uiSource(_ fileName: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ArcadeAppTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // 패키지 루트
        .appendingPathComponent("Sources/ArcadeUI/\(fileName)")
    return try String(contentsOf: url, encoding: .utf8)
}

// MARK: - 정정 사슬: 발견 → 확인 → 확정 → 재집계

/// 다시 누른 백필이 첫 페이지에서 실패해도 **이전 실행의 발견 목록이 남는다.**
///
/// 마지막 run 하나만 보면 발견 0건인 실패 run이 마지막이 되어 마법사에서 과거 상태 행이
/// 통째로 사라진다 — 잘못 추정된 상태는 그대로 채점되는데 고칠 화면이 없어지는 셈이라,
/// "폴백 추정 → 마법사에서 확인 → 확정 → 재집계" 사슬이 여기서 끊긴다.
@MainActor
@Test func discoveriesSurviveARetryThatFailsOnItsFirstPage() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let completed = try store.beginBackfill(jql: "assignee = currentUser()",
                                            at: iso("2026-08-13T09:00:00Z"), totalIssueCount: 100)
    try store.advanceBackfill(completed, nextPageToken: nil, processedIssueCount: 100,
                              discovered: ["Merged to Staging", "QA Done"], partiallyRestored: [])
    try store.finishBackfill(completed, at: iso("2026-08-13T09:30:00Z"), failure: nil)

    // 사용자가 "처음부터 다시 불러오기"를 눌렀고, 첫 페이지 조회가 실패한다.
    let source = StubChangelogSource(pages: [])
    source.failOnToken = .some(nil)
    let model = try makeModel(store: store, changelogSource: source, credentials: signedIn())
    await model.start()

    await model.startBackfill()

    #expect(model.lastBackfillFailure == "StubError", "실패가 실제로 일어났는지 확인한다")
    #expect(model.historyDiscoveredStatuses == ["Merged to Staging", "QA Done"],
            "실패한 재시도가 이전 실행의 발견 목록을 화면에서 지우면 안 된다")
}

/// "N개가 추정값으로 채점되고 있습니다"는 **지금 실제로 추정이 적용되는** 상태를 세야 한다.
/// 백필 시점의 발견 목록을 세면 사용자가 전부 지정한 뒤에도 개수가 줄지 않는다.
@MainActor
@Test func theGuessCountDropsAsTheUserFixesTheMapping() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let runId = try store.beginBackfill(jql: "q", at: iso("2026-08-13T09:00:00Z"),
                                        totalIssueCount: 10)
    try store.advanceBackfill(runId, nextPageToken: nil, processedIssueCount: 10,
                              discovered: ["Merged to Staging", "On Hold"], partiallyRestored: [])
    try store.finishBackfill(runId, at: iso("2026-08-13T09:30:00Z"), failure: nil)

    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: [:]))
    try workflow.saveFallbacks(
        WorkflowMap(statusToStage: ["Merged to Staging": .active, "On Hold": .done])
    )
    let model = try makeModel(store: store, credentials: signedIn(), workflow: workflow)
    await model.start()

    #expect(model.guessScoredStatuses == ["Merged to Staging", "On Hold"])

    // 하나는 단계를 지정하고, 하나는 아예 채점하지 않기로 한다.
    await model.confirmMapping(
        WorkflowMap(statusToStage: ["Merged to Staging": .review], excludedStatuses: ["On Hold"])
    )

    #expect(model.guessScoredStatuses.isEmpty,
            "지정한 것도 제외한 것도 더 이상 추정으로 채점되지 않는다")
    #expect(model.historyDiscoveredStatuses.count == 2,
            "발견 목록 자체는 백필의 사실이므로 그대로다 — 세는 값이 달라야 한다")
}

/// 카탈로그를 못 받은 run에서는 발견 상태가 전부 **0점**이지 추정이 아니다.
/// 그때 발견 개수를 세면 "상태 목록을 불러오지 못했습니다"(전부 0점)와
/// "N개가 추정값으로 채점되고 있습니다"가 같은 화면에 나란히 뜬다.
@MainActor
@Test func statusesWithNoFallbackAreNotCountedAsGuesses() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let runId = try store.beginBackfill(jql: "q", at: iso("2026-08-13T09:00:00Z"),
                                        totalIssueCount: 10)
    try store.advanceBackfill(runId, nextPageToken: nil, processedIssueCount: 10,
                              discovered: ["Merged to Staging"], partiallyRestored: [])
    try store.finishBackfill(runId, at: iso("2026-08-13T09:30:00Z"), failure: nil)

    let model = try makeModel(store: store, credentials: signedIn())
    await model.start()

    #expect(model.historyDiscoveredStatuses == ["Merged to Staging"])
    #expect(model.guessScoredStatuses.isEmpty, "폴백이 없으면 추정이 아니라 0점이다")
}

/// **이 태스크의 존재 이유.** 잘못 추정된 상태를 끄면 그 자리에서 XP가 정정된다.
///
/// 제외 목록이 없으면 사용자가 할 수 있는 일은 다른 단계로 바꾸는 것뿐이고, 폴백이
/// 밑에 깔려 계속 채점된다 — 실물에서 보류 성격의 상태가 done으로 추정돼 마감 보너스까지
/// 받고 있었다.
@MainActor
@Test func excludingAGuessedStatusRemovesItsXPRightAway() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let event = DomainEvent(
        issueKey: "MPT-1", kind: .statusChanged,
        fromStatus: "In Progress", toStatus: "On Hold",
        observedAt: iso("2026-08-10T00:00:00Z"), actorAccountId: "acc-me",
        priorUpdatedAt: iso("2026-08-01T00:00:00Z")
    )
    _ = try store.appendBackfillEvents([event], historyIds: ["h-1"], fullyRestoredKeys: [])
    let workflow = InMemoryWorkflowStore(
        seeded: WorkflowMap(statusToStage: ["In Progress": .active])
    )
    // 보류 성격의 상태가 statusCategory상 done이라 완료 전이로 추정됐다.
    try workflow.saveFallbacks(WorkflowMap(statusToStage: ["On Hold": .done]))
    let model = try makeModel(store: store, credentials: signedIn(), workflow: workflow)
    await model.start()

    let before = try #require(model.lifetimeSummary)
    #expect(before.totalXP > 0, "추정대로면 active -> done 전진이라 XP가 붙는다")

    await model.confirmMapping(
        WorkflowMap(statusToStage: ["In Progress": .active], excludedStatuses: ["On Hold"])
    )

    let after = try #require(model.lifetimeSummary)
    #expect(after.totalXP == 0, "끈 상태는 추정도 적용되지 않아야 한다")
}

/// 제외는 저장돼 다음 실행까지 살아남는다. 메모리에만 있으면 사용자가 끈 상태가
/// 앱을 다시 켜는 순간 추정 채점으로 되돌아간다.
@MainActor
@Test func exclusionsSurviveRelaunch() async throws {
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: [:]))
    let model = try makeModel(credentials: signedIn(), workflow: workflow)
    await model.start()
    await model.confirmMapping(
        WorkflowMap(statusToStage: ["In Progress": .active], excludedStatuses: ["On Hold"])
    )

    let relaunched = try makeModel(credentials: signedIn(), workflow: workflow)
    await relaunched.start()

    #expect(relaunched.currentMapping.excludedStatuses == ["On Hold"])
}

// MARK: - 백필 중 동기화 정지

/// 백필이 도는 동안에는 라이브 동기화가 멈춘다. 백필이 changelog를 받은 뒤 이벤트를
/// 넣기까지의 창에 동기화가 같은 티켓의 새 전이를 기록하면, 그 전이는 백필의 대체 로직에
/// 지워진다 — 다음 백필이 복원할 때까지 점수가 튄다.
@MainActor
@Test func backfillStopsLiveSyncingWhileItRuns() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = StubChangelogSource(pages: [([], nil)])
    let model = try makeModel(store: store, changelogSource: source, credentials: signedIn())
    await model.start()
    model.startSyncing()
    #expect(model.isSyncScheduled, "멈출 것이 실제로 돌고 있어야 이 테스트가 무언가를 검증한다")

    source.onFetchPage = { _ in
        await MainActor.run {
            #expect(model.isSyncScheduled == false, "백필이 도는 동안에는 동기화가 멈춰 있어야 한다")
        }
    }

    await model.startBackfill()

    #expect(source.requestedTokens.count == 1, "훅이 돌지 않으면 위 검사는 조용히 통과한다")
    #expect(model.isSyncScheduled, "끝나면 되살려야 한다 — 안 그러면 앱이 조용히 갱신을 멈춘다")
    model.stopSyncing()
}

/// 백필이 끝났다고 **원래 멈춰 있던** 동기화를 켜면 안 된다.
/// 로그인 직후 설정에서 바로 백필을 누른 경우가 그렇다.
@MainActor
@Test func backfillDoesNotStartSyncingThatWasNotRunning() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = StubChangelogSource(pages: [([], nil)])
    let model = try makeModel(store: store, changelogSource: source, credentials: signedIn())
    await model.start()
    #expect(model.isSyncScheduled == false)

    await model.startBackfill()

    #expect(model.isSyncScheduled == false, "백필이 꺼져 있던 동기화를 켜면 안 된다")
}

// MARK: - 화면 배선 (정정 사슬)

/// 설정 화면이 발견 개수가 아니라 **지금 추정이 적용되는** 개수를 세는지 소스로 확인한다.
/// ArcadeUI에는 테스트 타깃이 없으므로 `ModuleBoundaryTests`가 색 리터럴을 잡는 것과
/// 같은 방식이다.
@Test func settingsCountsWhatIsActuallyGuessedRightNow() throws {
    let text = try uiSource("SettingsView.swift")

    let usesLiveCount = text.contains("model.guessScoredStatuses")
    let usesSnapshotCount = text.contains("model.historyDiscoveredStatuses.count")
    #expect(usesLiveCount, "지금 추정이 적용되는 상태를 세야 매핑한 뒤 개수가 줄어든다")
    #expect(!usesSnapshotCount, "백필 시점의 스냅샷을 세면 무엇을 고쳐도 개수가 그대로다")
}

/// 마법사가 "채점하지 않음"을 실제로 저장하는지 소스로 확인한다.
/// 저장하지 않으면 사용자가 끈 상태에 폴백이 다시 깔려, 화면은 껐다고 말하는데
/// 채점은 계속된다.
@Test func theMappingWizardCanTurnAStatusOff() throws {
    let text = try uiSource("WorkflowMappingView.swift")

    let seedsExclusions =
        text.contains("State(initialValue: model.currentMapping.excludedStatuses)")
    let savesExclusions = text.contains("excludedStatuses: excluded")
    #expect(seedsExclusions, "다시 연 마법사가 기존 제외 목록을 들고 있어야 한다")
    #expect(savesExclusions, "고른 제외가 저장되지 않으면 폴백이 다시 깔린다")
}

/// 플로어가 **지금 추정이 적용되는** 개수를 세는지 소스로 확인한다.
///
/// 설정 시트 안에만 있으면 사용자가 열어보기 전까지 모른다. 실물에서 상태 14개가
/// 추정으로 채점되고 있었고 그중 하나(`보류` → `done`)는 방향까지 틀렸는데,
/// 플로어에는 그 사실이 어디에도 없었다 — 있는 것은 성격이 다른 미매핑 배지뿐이다.
@Test func theFloorShowsHowManyStatusesAreScoredByGuess() throws {
    let text = try uiSource("ArcadeFloorView.swift")

    #expect(text.contains("model.guessScoredStatuses"),
            "플로어가 추정 채점 개수를 보여줘야 사용자가 설정을 열기 전에 안다")
    #expect(!text.contains("model.historyDiscoveredStatuses"),
            "백필 시점의 스냅샷을 세면 매핑을 고쳐도 개수가 줄지 않는다")
}

/// 두 배지가 색으로 갈리는지 확인한다.
///
/// 미매핑은 확실한 손실(0점)이고 추정은 대개 맞다 — 실물 14개 중 13개는 타당했다.
/// 둘 다 `danger`로 칠하면 진짜 위험이 그 안에 묻힌다.
///
/// 파일 어딘가에 `theme.accent`가 있는지만 보면 가드가 되지 않는다 — 이 화면은
/// 다른 곳에서도 그 토큰을 쓴다. 추정 문구가 나온 자리부터 좁은 창 안에서 찾는다.
@Test func theTwoMappingBadgesAreToldApartByColour() throws {
    let text = try uiSource("ArcadeFloorView.swift")

    let phrase = "추정으로 채점 중인 상태"
    let start = try #require(text.range(of: phrase), "추정 배지 문구를 찾지 못했다")
    let window = text[start.upperBound...].prefix(200)

    #expect(window.contains("theme.accent"),
            "추정 배지는 확인을 청하는 것이지 손실을 알리는 것이 아니다")
    #expect(!window.contains("theme.danger"),
            "미매핑과 같은 색이면 무엇이 더 급한지 구분되지 않는다")
}

/// 배지를 눌러 마법사로 갈 수 있는지 확인한다.
///
/// 죽은 텍스트로 두면 무엇을 고쳐야 하는지 알려주고도 고칠 길을 주지 않는다.
/// 둘 중 하나만 눌리면 사용자는 안 되는 쪽을 고장으로 읽으므로 둘 다 눌린다.
@Test func bothMappingBadgesOpenTheWizard() throws {
    let text = try uiSource("ArcadeFloorView.swift")

    // 배지 둘이 같은 헬퍼를 거치므로 `reopenMapping()` 자체는 한 번만 나온다.
    // 세어야 할 것은 호출 횟수가 아니라 **그 헬퍼를 쓰는 배지의 수**다.
    let badges = text.components(separatedBy: "mappingBadge(").count - 1
    #expect(badges >= 3, "배지 둘과 헬퍼 정의 하나 — 둘 다 같은 길로 마법사에 이어져야 한다")
    #expect(text.contains("reopenMapping()"), "배지가 마법사를 열어야 한다")
}

/// 플로어가 동기화 진행을 화면에 알리는지 소스로 확인한다.
///
/// 모델에 `isSyncing`이 있어도 화면이 읽지 않으면 아무 소용이 없다. 새로고침을 눌러도
/// 반응이 없어 앱이 멈춘 것처럼 보인다는 검수 지적이 이 배선을 요구했다.
@Test func theFloorShowsThatASyncIsRunning() throws {
    let text = try uiSource("ArcadeFloorView.swift")

    #expect(text.contains("model.isSyncing"), "화면이 동기화 진행을 읽어야 한다")
    #expect(text.contains("ProgressView()"), "정지한 문구만으로는 진행이 읽히지 않는다")
    #expect(text.contains(".disabled(model.isSyncing)"),
            "도는 중에 새로고침을 또 누르면 요청이 쌓인다")
}
