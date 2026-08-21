import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

private struct StubError: Error, Equatable {}

/// 설명이 수다스러운 에러. 저장되는 실패 사유에 이런 내용이 새는지 확인하는 데 쓴다.
private struct ChattyError: Error, CustomStringConvertible {
    var description = "GET https://tenant.example.invalid/rest/api/3/search?jql=... 401"
    var localizedDescription: String { description }
}

/// 클로저 안에서 자기 자신을 취소하려면 참조 순환을 끊을 자리가 필요하다.
private final class RunTaskBox: @unchecked Sendable {
    var task: Task<BackfillOutcome, any Error>?
}

/// 스토어 호출 횟수를 센다. 엔진이 티켓마다 부르면 `appendBackfillEvents`가 호출마다
/// 기존 백필 이벤트를 전량 조회해 2차식이 된다.
@MainActor
private final class CallCountingStore: ArcadeStore {
    private(set) var appendBatchSizes: [Int] = []

    override func appendBackfillEvents(
        _ events: [DomainEvent], historyIds: [String]
    ) throws -> Int {
        appendBatchSizes.append(events.count)
        return try super.appendBackfillEvents(events, historyIds: historyIds)
    }
}

private let catalogEntries = [
    JiraStatusCatalogEntry(id: "10009", name: "To Do", categoryKey: "new"),
    JiraStatusCatalogEntry(id: "10016", name: "In Progress", categoryKey: "indeterminate"),
    JiraStatusCatalogEntry(id: "10071", name: "Merged to Staging", categoryKey: "indeterminate"),
]

/// 스크립트대로 페이지를 돌려주는 테스트용 소스.
private final class ScriptedChangelogSource: ChangelogSource, @unchecked Sendable {
    var pages: [(issues: [JiraIssueWithChangelog], nextPageToken: String?)]
    var supplements: [String: JiraChangelogPage] = [:]
    var catalog: [JiraStatusCatalogEntry] = catalogEntries
    var catalogError: (any Error)?
    var failSupplementFor: Set<String> = []
    private(set) var requestedTokens: [String?] = []
    /// 이 토큰으로 페이지를 요청하면 던진다. `nil` 키는 첫 페이지다.
    /// "1페이지를 훑은 뒤에 실패"를 만들어 페이지 경계 진행 저장을 확인하는 데 쓴다.
    var pageErrors: [String?: any Error] = [:]
    /// 보충 조회를 요청받는 순간 부른다. 보충 도중의 취소를 재현하는 자리다.
    var onSupplementRequest: (@Sendable (String) -> Void)?

    init(pages: [(issues: [JiraIssueWithChangelog], nextPageToken: String?)]) {
        self.pages = pages
    }

    func fetchPage(jql: String, pageToken: String?)
        async throws -> (issues: [JiraIssueWithChangelog], nextPageToken: String?) {
        requestedTokens.append(pageToken)
        if let error = pageErrors[pageToken] { throw error }
        guard !pages.isEmpty else { return ([], nil) }
        return pages.removeFirst()
    }

    /// 보충 조회는 페이지네이션된다. startAt마다 다른 응답을 주려면
    /// `supplementPages[key]`에 순서대로 넣는다. 없으면 `supplements[key]` 한 장을 쓴다.
    var supplementPages: [String: [JiraChangelogPage]] = [:]
    private(set) var supplementStartAts: [String: [Int]] = [:]

    func fetchIssueChangelog(key: String, startAt: Int) async throws -> JiraChangelogPage {
        supplementStartAts[key, default: []].append(startAt)
        onSupplementRequest?(key)
        if failSupplementFor.contains(key) { throw StubError() }
        if var queue = supplementPages[key], !queue.isEmpty {
            let next = queue.removeFirst()
            supplementPages[key] = queue
            return next
        }
        return supplements[key] ?? JiraChangelogPage(startAt: 0, maxResults: 100,
                                                     total: 0, histories: [])
    }

    func fetchStatusCatalog() async throws -> [JiraStatusCatalogEntry] {
        if let catalogError { throw catalogError }
        return catalog
    }
}

private func statusHistory(
    id: String, at: Date, author: String,
    fromId: String, from: String, toId: String, to: String
) -> JiraChangelogHistory {
    JiraChangelogHistory(
        id: id, createdAt: at, authorAccountId: author,
        items: [JiraChangelogItem(field: "status", fromId: fromId, fromString: from,
                                  toId: toId, toString: to)]
    )
}

private func transitionIssue(
    key: String, historyId: String, at: Date, author: String,
    fromId: String = "10009", from: String = "To Do",
    toId: String = "10016", to: String = "In Progress",
    total: Int? = nil
) -> JiraIssueWithChangelog {
    let histories = [statusHistory(id: historyId, at: at, author: author,
                                   fromId: fromId, from: from, toId: toId, to: to)]
    return JiraIssueWithChangelog(
        key: key, createdAt: at.addingTimeInterval(-days(30)), dueDate: nil,
        changelog: JiraChangelogPage(startAt: 0, maxResults: 10,
                                     total: total ?? histories.count, histories: histories)
    )
}

@MainActor
@Test func backfillWalksEveryPage() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1",
                          at: iso("2023-02-01T00:00:00Z"), author: "acc-me")], "tok-2"),
        ([transitionIssue(key: "MPT-2", historyId: "2",
                          at: iso("2023-03-01T00:00:00Z"), author: "acc-me")], nil),
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(outcome.processedIssues == 2)
    #expect(outcome.insertedEvents == 2)
    #expect(source.requestedTokens == [nil, "tok-2"])
    // throwing 호출을 #expect 안에 두면 클로저가 non-throwing으로 추론돼 경고가 난다.
    let events = try store.loadEvents()
    #expect(events.count == 2)
}

/// 두 번 돌려도 이벤트가 늘지 않는다 — historyId 중복 검사가 막는다.
@MainActor
@Test func runningTwiceInsertsNothingNew() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    func makeSource() -> ScriptedChangelogSource {
        ScriptedChangelogSource(pages: [
            ([transitionIssue(key: "MPT-1", historyId: "1",
                              at: iso("2023-02-01T00:00:00Z"), author: "acc-me")], nil)
        ])
    }
    let first = BackfillEngine(source: makeSource(), store: store, workflow: demoWorkflow)
    _ = try await first.run(jql: "q", now: iso("2026-08-13T00:00:00Z"), progress: { _, _ in })

    let second = BackfillEngine(source: makeSource(), store: store, workflow: demoWorkflow)
    let outcome = try await second.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(outcome.insertedEvents == 0)
    let events = try store.loadEvents()
    #expect(events.count == 1)
}

/// changelog가 잘려 왔으면 보충 조회한다. 놓치면 오래된 티켓의 전이가 조용히 사라진다.
@MainActor
@Test func truncatedChangelogIsSupplemented() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1", at: iso("2023-02-01T00:00:00Z"),
                          author: "acc-me", total: 2)], nil)   // total 2 > histories 1
    ])
    source.supplements["MPT-1"] = JiraChangelogPage(
        startAt: 0, maxResults: 100, total: 2,
        histories: [
            statusHistory(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                          fromId: "10009", from: "To Do", toId: "10016", to: "In Progress"),
            statusHistory(id: "9", at: iso("2023-02-05T00:00:00Z"), author: "acc-me",
                          fromId: "10016", from: "In Progress",
                          toId: "10071", to: "Merged to Staging"),
        ]
    )
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(outcome.insertedEvents == 2, "보충 조회로 두 번째 전이까지 들어와야 한다")
}

/// 보충 조회도 페이지네이션된다. 한 장만 받고 끝내면 history가 100건을 넘는 오래된
/// 티켓이 보충 후에도 잘린 채 남는다 — 두 번째 페이지를 startAt으로 이어 받아야 한다.
@MainActor
@Test func supplementFollowsItsOwnPagination() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1", at: iso("2023-02-01T00:00:00Z"),
                          author: "acc-me", total: 3)], nil)
    ])
    source.supplementPages["MPT-1"] = [
        JiraChangelogPage(startAt: 0, maxResults: 2, total: 3, histories: [
            statusHistory(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                          fromId: "10009", from: "To Do", toId: "10016", to: "In Progress"),
            statusHistory(id: "2", at: iso("2023-02-05T00:00:00Z"), author: "acc-me",
                          fromId: "10016", from: "In Progress", toId: "10009", to: "To Do"),
        ]),
        JiraChangelogPage(startAt: 2, maxResults: 2, total: 3, histories: [
            statusHistory(id: "3", at: iso("2023-02-09T00:00:00Z"), author: "acc-me",
                          fromId: "10009", from: "To Do",
                          toId: "10071", to: "Merged to Staging"),
        ]),
    ]
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(source.supplementStartAts["MPT-1"] == [0, 2], "두 번째 페이지를 startAt=2로 이어 받는다")
    #expect(outcome.insertedEvents == 3)
    #expect(outcome.partiallyRestored.isEmpty)
}

/// 보충 조회가 실패해도 나머지는 계속된다. 부분 실패를 전체 실패로 만들지 않는다.
@MainActor
@Test func supplementFailureIsRecordedButDoesNotStopTheRun() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([
            transitionIssue(key: "MPT-1", historyId: "1", at: iso("2023-02-01T00:00:00Z"),
                            author: "acc-me", total: 5),
            transitionIssue(key: "MPT-2", historyId: "2", at: iso("2023-03-01T00:00:00Z"),
                            author: "acc-me"),
        ], nil)
    ])
    source.failSupplementFor = ["MPT-1"]
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(outcome.partiallyRestored == ["MPT-1"])
    #expect(outcome.processedIssues == 2, "실패한 티켓도 처리 개수에는 든다")
    // 정확히 2다 — MPT-1은 보충에 실패해 원본 1건을 유지하고, MPT-2가 1건이다.
    let events = try store.loadEvents()
    #expect(events.count == 2)
}

/// 보충이 짧게 와도(서버가 `total`보다 적게 주고 멈춤) 부분 복원으로 기록한다.
/// 지금까지는 보충이 **던졌을 때만** 기록돼, 전이 5개 중 1개로 XP가 계산되는데도
/// 사용자는 이 티켓이 온전히 소급됐다고 믿었다.
@MainActor
@Test func shortSupplementIsRecordedAsPartiallyRestored() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1", at: iso("2023-02-01T00:00:00Z"),
                          author: "acc-me", total: 5)], nil)
    ])
    // total 5를 말하면서 1건만 준다. 그다음 요청에는 스텁 기본값인 빈 페이지가 온다 —
    // 빈 페이지의 total(0)을 믿으면 "다 받았다"로 보인다.
    source.supplementPages["MPT-1"] = [
        JiraChangelogPage(startAt: 0, maxResults: 100, total: 5, histories: [
            statusHistory(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                          fromId: "10009", from: "To Do", toId: "10016", to: "In Progress"),
        ]),
    ]
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(outcome.partiallyRestored == ["MPT-1"], "5건 중 1건만 받았으면 완전 복원이 아니다")
    #expect(outcome.insertedEvents == 1)
}

/// 상태 카탈로그 조회가 실패해도 ①③만으로 degraded 진행한다(스펙 §8).
///
/// degraded의 증거는 매핑에 없는 상태가 ③으로 떨어지는 것이다 — 카탈로그가 있었다면
/// "Merged to Staging"은 statusCategory로 ②까지 갔을 텐데, 없으니 미매핑으로 남는다.
/// (매핑에 있는 상태는 카탈로그 없이도 ①로 해석되므로 degraded를 보여주지 못한다.)
@MainActor
@Test func catalogFailureDegradesInsteadOfStopping() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1", at: iso("2023-02-01T00:00:00Z"),
                          author: "acc-me", toId: "10071", to: "Merged to Staging")], nil)
    ])
    source.catalogError = StubError()
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(outcome.insertedEvents == 1)
    #expect(outcome.catalogUnavailable)
    #expect(outcome.discoveredStatuses.contains("Merged to Staging"))
    #expect(outcome.resolvedFallbacks.isEmpty, "카탈로그가 없으면 ② 폴백 자체가 없다")
}

/// 카탈로그 조회 도중 취소되면 그대로 던진다. try?로 뭉뚱그리면 사용자가 중단을 눌러도
/// 카탈로그 단계에서만 조용히 넘어가고 백필이 계속 돈다.
@MainActor
@Test func cancellationDuringCatalogFetchIsNotSwallowed() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1", at: iso("2023-02-01T00:00:00Z"),
                          author: "acc-me")], nil)
    ])
    source.catalogError = CancellationError()
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    await #expect(throws: CancellationError.self) {
        _ = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                 progress: { _, _ in })
    }
    let events = try store.loadEvents()
    #expect(events.isEmpty, "취소됐으면 페이지를 훑지 않는다")
}

/// 폴백으로 처리한 상태가 수집된다 — 매핑 마법사 후보가 된다.
@MainActor
@Test func fallbackStatusesAreCollected() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1", at: iso("2023-02-01T00:00:00Z"),
                          author: "acc-me", fromId: "10016", from: "In Progress",
                          toId: "10071", to: "Merged to Staging")], nil)
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(outcome.discoveredStatuses.contains("Merged to Staging"))
}

/// 폴백 매핑이 결과에 실려 나온다. 엔진은 ArcadeCore에 있고 폴백 저장소는 ArcadeApp에
/// 있어 엔진이 직접 저장할 수 없다 — 이게 없으면 폴백은 마법사 후보 목록만 만들고
/// XP에는 아무 영향이 없다.
@MainActor
@Test func resolvedFallbacksReachTheOutcome() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1", at: iso("2023-02-01T00:00:00Z"),
                          author: "acc-me", fromId: "10016", from: "In Progress",
                          toId: "10071", to: "Merged to Staging")], nil)
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(outcome.resolvedFallbacks["Merged to Staging"] == .active)
    // 실효 맵으로 합쳐야 비로소 채점기가 이 상태를 안다(Task 10b).
    #expect(demoWorkflow.merging(outcome.resolvedFallbacks).stage(for: "Merged to Staging") == .active)
}

/// 재개는 저장된 페이지 토큰부터 요청한다. 처음부터 다시 훑으면 1,000여 건을
/// 두 번 받는 셈이고, 이어받은 진행 수도 잃는다.
@MainActor
@Test func resumeContinuesFromStoredPageToken() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let runId = try store.beginBackfill(jql: "q", at: iso("2026-08-12T00:00:00Z"),
                                        totalIssueCount: 2)
    try store.advanceBackfill(runId, nextPageToken: "tok-2", processedIssueCount: 1,
                              discovered: [], partiallyRestored: [])

    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-2", historyId: "2",
                          at: iso("2023-03-01T00:00:00Z"), author: "acc-me")], nil)
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       resume: true, progress: { _, _ in })

    #expect(source.requestedTokens == ["tok-2"], "저장된 토큰부터 요청한다")
    #expect(outcome.processedIssues == 2, "이어받은 진행 수에 이번 페이지가 더해진다")
    // 이어받은 run을 그대로 닫는다. 새 run을 만들었다면 미완료 run이 남아
    // "이어서 하시겠습니까"가 영원히 뜬다.
    let resumable = try store.resumableBackfill()
    #expect(resumable == nil)
}

/// 범위(jql)가 달라졌으면 이어받지 않는다 — 다른 범위의 진행 지점은 이어붙일 수 없다.
@MainActor
@Test func resumeWithDifferentJqlStartsOver() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let runId = try store.beginBackfill(jql: "다른 범위", at: iso("2026-08-12T00:00:00Z"),
                                        totalIssueCount: 2)
    try store.advanceBackfill(runId, nextPageToken: "tok-2", processedIssueCount: 1,
                              discovered: [], partiallyRestored: [])

    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1",
                          at: iso("2023-02-01T00:00:00Z"), author: "acc-me")], nil)
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       resume: true, progress: { _, _ in })

    #expect(source.requestedTokens == [nil], "처음부터 시작한다")
    #expect(outcome.processedIssues == 1, "다른 범위의 진행 수를 이어받지 않는다")
}

/// 서버가 같은 페이지 토큰을 다시 주면 무한 루프다. 사용자에게는 앱이 멈춘 것으로 보인다.
@MainActor
@Test func repeatedPageTokenStopsTheRun() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1",
                          at: iso("2023-02-01T00:00:00Z"), author: "acc-me")], "tok-loop"),
        ([transitionIssue(key: "MPT-2", historyId: "2",
                          at: iso("2023-03-01T00:00:00Z"), author: "acc-me")], "tok-loop"),
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    await #expect(throws: BackfillError.repeatedPageToken) {
        _ = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                 progress: { _, _ in })
    }
    // 여기까지 넣은 이벤트는 유효하고, 진행 지점이 저장돼 있어 나중에 이어받을 수 있다.
    let events = try store.loadEvents()
    #expect(events.count == 2)
    let resumable = try store.resumableBackfill()
    #expect(resumable != nil, "실패한 run은 미완료로 남아 재개 대상이 된다")
}

/// 진행률 콜백이 페이지마다 불린다.
@MainActor
@Test func progressIsReportedPerPage() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1",
                          at: iso("2023-02-01T00:00:00Z"), author: "acc-me")], "t2"),
        ([transitionIssue(key: "MPT-2", historyId: "2",
                          at: iso("2023-03-01T00:00:00Z"), author: "acc-me")], nil),
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    var reports: [Int] = []
    _ = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                             progress: { processed, _ in reports.append(processed) })

    #expect(reports == [1, 2])
}

/// 총계를 모르면 nil을 그대로 넘긴다. 처리한 수를 총계로 삼으면 진행률이 늘 100%로 보인다.
@MainActor
@Test func progressKeepsUnknownTotalAsNil() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1",
                          at: iso("2023-02-01T00:00:00Z"), author: "acc-me")], nil)
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    var totals: [Int?] = []
    _ = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                             progress: { _, total in totals.append(total) })

    #expect(totals == [nil])
}

/// 페이지 경계마다 진행 상황이 **DB에** 저장된다. 저장하지 않으면 재개가 늘 처음부터
/// 시작해 1,200건을 매번 다시 받고(이 기능이 존재하는 이유 자체), 매핑 마법사 후보도
/// 빈 목록이 된다. 1페이지를 훑은 직후 2페이지 요청을 실패시켜 그 시점의 저장분을 본다.
@MainActor
@Test func pageBoundaryProgressIsPersisted() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([
            transitionIssue(key: "MPT-1", historyId: "1", at: iso("2023-02-01T00:00:00Z"),
                            author: "acc-me", fromId: "10016", from: "In Progress",
                            toId: "10071", to: "Merged to Staging"),
            transitionIssue(key: "MPT-2", historyId: "2", at: iso("2023-03-01T00:00:00Z"),
                            author: "acc-me"),
        ], "tok-2"),
    ])
    source.pageErrors["tok-2"] = StubError()
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    await #expect(throws: StubError.self) {
        _ = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                 progress: { _, _ in })
    }

    let resumable = try #require(try store.resumableBackfill())
    #expect(resumable.nextPageToken == "tok-2", "다음 페이지 커서가 남아야 이어받을 수 있다")
    #expect(resumable.processedIssueCount == 2, "1페이지에서 처리한 티켓 수가 남는다")
    #expect(resumable.discovered == ["Merged to Staging"], "마법사 후보도 함께 남는다")
}

/// 페이지를 훑는 도중의 취소가 루프를 끊고 run을 미완료로 남긴다.
/// 이 경로에 커버리지가 없어 `Task.checkCancellation()`을 지워도 아무도 몰랐다.
@MainActor
@Test func cancellationDuringPageWalkStopsTheRun() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1",
                          at: iso("2023-02-01T00:00:00Z"), author: "acc-me")], "tok-2"),
        ([transitionIssue(key: "MPT-2", historyId: "2",
                          at: iso("2023-03-01T00:00:00Z"), author: "acc-me")], nil),
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    // 1페이지가 끝난 시점(진행률 콜백)에 사용자가 중단을 누른 상황이다.
    // MainActor 위에 있으므로 Task 본문은 아래 await까지 시작하지 않는다 — box.task가 먼저 채워진다.
    let box = RunTaskBox()
    box.task = Task { @MainActor in
        try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                             progress: { _, _ in box.task?.cancel() })
    }
    await #expect(throws: CancellationError.self) {
        _ = try await box.task?.value
    }

    #expect(source.requestedTokens == [nil], "취소 뒤에는 다음 페이지를 요청하지 않는다")
    let resumable = try store.resumableBackfill()
    #expect(resumable != nil, "취소된 run은 미완료로 남아 재개 대상이 된다")
    let failure = try store.lastBackfillFailure()
    #expect(failure == nil, "사용자가 스스로 누른 중단은 실패가 아니다")
}

/// 보충 조회 도중의 취소를 삼키면 "부분 복원"이라는 거짓을 남기고 백필이 끝까지 돌아
/// run이 정상 완료로 닫힌다. 그러면 재개 제안이 뜨지 않아 잘린 changelog가 영구히 남는다.
@MainActor
@Test func cancellationDuringSupplementIsNotSwallowed() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([
            transitionIssue(key: "MPT-1", historyId: "1", at: iso("2023-02-01T00:00:00Z"),
                            author: "acc-me", total: 3),
            transitionIssue(key: "MPT-2", historyId: "2", at: iso("2023-03-01T00:00:00Z"),
                            author: "acc-me"),
        ], nil)
    ])
    // 첫 장을 받고 두 번째 장을 요청하기 직전에 취소가 걸린다.
    source.supplementPages["MPT-1"] = [
        JiraChangelogPage(startAt: 0, maxResults: 2, total: 3, histories: [
            statusHistory(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                          fromId: "10009", from: "To Do", toId: "10016", to: "In Progress"),
            statusHistory(id: "2", at: iso("2023-02-05T00:00:00Z"), author: "acc-me",
                          fromId: "10016", from: "In Progress", toId: "10009", to: "To Do"),
        ]),
    ]
    let box = RunTaskBox()
    source.onSupplementRequest = { [box] _ in box.task?.cancel() }
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    box.task = Task { @MainActor in
        try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                             progress: { _, _ in })
    }
    await #expect(throws: CancellationError.self) {
        _ = try await box.task?.value
    }

    let events = try store.loadEvents()
    #expect(events.isEmpty, "취소된 페이지는 통째로 버려진다 — 재개 때 다시 방문한다")
    let resumable = try store.resumableBackfill()
    #expect(resumable != nil, "취소된 run은 미완료로 남아 재개 대상이 된다")
    #expect(resumable?.partiallyRestored.isEmpty == true,
            "취소는 부분 복원이 아니다 — 서버는 멀쩡했고 사용자가 중단했다")
}

/// 실패 사유가 기록되되 run은 미완료로 남는다. 이 둘을 함께 만족시키지 않으면
/// `lastBackfillFailure()`가 구조적으로 영원히 nil이거나(끝난 run만 봄),
/// 재개 지점을 잃는다(finishedAt을 채움).
@MainActor
@Test func failureIsRecordedWithoutClosingTheRun() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1",
                          at: iso("2023-02-01T00:00:00Z"), author: "acc-me")], "tok-loop"),
        ([transitionIssue(key: "MPT-2", historyId: "2",
                          at: iso("2023-03-01T00:00:00Z"), author: "acc-me")], "tok-loop"),
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    await #expect(throws: BackfillError.repeatedPageToken) {
        _ = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                 progress: { _, _ in })
    }

    let failure = try store.lastBackfillFailure()
    #expect(failure == "BackfillError.repeatedPageToken")
    let resumable = try store.resumableBackfill()
    #expect(resumable != nil, "사유를 적어도 재개 가능성은 지킨다")
}

/// 저장하는 실패 사유에 호스트·JQL·토큰이 새면 안 된다. 이 문구는 설정 화면에
/// 그대로 노출된다. ArcadeApp의 redactedErrorDescription은 모듈 경계상 쓸 수 없다.
@MainActor
@Test func recordedFailureDoesNotLeakErrorDetails() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [])
    source.pageErrors[nil] = ChattyError()
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    await #expect(throws: ChattyError.self) {
        _ = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                 progress: { _, _ in })
    }

    let failure = try #require(try store.lastBackfillFailure())
    #expect(failure == "ChattyError", "에러 타입 이름만 남긴다")
    #expect(!failure.contains("example.invalid"))
    #expect(!failure.contains("jql"))
}

/// 이벤트를 페이지 단위로 한 번에 넣는다. 티켓마다 부르면 appendBackfillEvents가
/// 호출마다 기존 백필 이벤트를 전량 조회해 2차식이 된다 —
/// 실측으로 티켓 200/400/800건이 3.09초 / 11.37초 / 46.34초였다.
@MainActor
@Test func eventsAreInsertedOncePerPageNotOncePerIssue() async throws {
    let store = CallCountingStore(container: try ArcadeStore.makeInMemoryContainer())
    func issues(_ range: ClosedRange<Int>) -> [JiraIssueWithChangelog] {
        range.map { n in
            transitionIssue(key: "MPT-\(n)", historyId: "\(n)",
                            at: iso("2023-02-01T00:00:00Z")
                                .addingTimeInterval(Double(n) * 86_400),
                            author: "acc-me")
        }
    }
    let source = ScriptedChangelogSource(pages: [
        (issues(1...5), "tok-2"),
        (issues(6...8), nil),
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(store.appendBatchSizes == [5, 3], "페이지당 한 번, 그 페이지의 전이를 전부 담아")
    #expect(outcome.insertedEvents == 8, "묶어 넣어도 삽입 수는 같다")
    let events = try store.loadEvents()
    #expect(events.count == 8)
}

/// 같은 페이지 안에 같은 historyId가 두 번 나와도 한 번만 들어간다.
/// 티켓마다 부르던 때는 두 번째 호출이 DB를 다시 조회해 걸렀지만,
/// 묶어 넣으면 한 호출 안에서 걸러야 한다.
@MainActor
@Test func duplicateHistoryIdsWithinAPageAreInsertedOnce() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let duplicated = transitionIssue(key: "MPT-1", historyId: "1",
                                     at: iso("2023-02-01T00:00:00Z"), author: "acc-me")
    let source = ScriptedChangelogSource(pages: [([duplicated, duplicated], nil)])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(outcome.insertedEvents == 1)
    let events = try store.loadEvents()
    #expect(events.count == 1)
}
