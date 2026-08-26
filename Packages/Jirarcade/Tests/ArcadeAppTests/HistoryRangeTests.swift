import Testing
import Foundation
@testable import ArcadeApp
@testable import ArcadeCore
import JiraKit

/// 과거 기록을 어디까지 읽을지 — 백필 JQL의 범위와, 누르기 전에 보여주는 건수 추정.

@Test func theRangeNarrowsOnlyTheBackfillQuery() {
    #expect(HistoryRange.all.backfillJQL == "assignee = currentUser()")
    #expect(HistoryRange.quarter.backfillJQL == "assignee = currentUser() AND updated >= -90d")
    #expect(HistoryRange.halfYear.backfillJQL == "assignee = currentUser() AND updated >= -180d")
    #expect(HistoryRange.year.backfillJQL == "assignee = currentUser() AND updated >= -365d")
}

@Test func theRangeRoundTripsThroughItsRawValue() {
    for range in HistoryRange.allCases {
        #expect(HistoryRange(rawValue: range.rawValue) == range)
    }
}

/// 백필과 추정이 같은 질문을 하는지 보려면 둘이 받은 JQL을 붙잡아야 한다.
private final class RecordingSource: ChangelogSource, @unchecked Sendable {
    private let lock = NSLock()
    private var jqls: [String] = []
    private var counts: [String] = []
    var count: Int?

    var pageJQLs: [String] { lock.withLock { jqls } }
    var countJQLs: [String] { lock.withLock { counts } }

    func fetchPage(jql: String, pageToken: String?)
        async throws -> (issues: [JiraIssueWithChangelog], nextPageToken: String?) {
        lock.withLock { jqls.append(jql) }
        return ([], nil)
    }
    func fetchIssueChangelog(key: String, startAt: Int) async throws -> JiraChangelogPage {
        JiraChangelogPage(startAt: 0, maxResults: 100, total: 0, histories: [])
    }
    func fetchStatusCatalog() async throws -> [JiraStatusCatalogEntry] { [] }
    func approximateIssueCount(jql: String) async throws -> Int {
        lock.withLock { counts.append(jql) }
        guard let count else { throw StubError() }
        return count
    }
}

@MainActor
private func signedIn(_ source: RecordingSource) async throws -> AppModel {
    let model = try makeModel(
        changelogSource: source,
        workflow: InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["진행 중": .active]))
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    return model
}

/// `historyRange`는 UserDefaults에 남는다. 다른 테스트가 그 값을 물려받지 않도록 지운다.
@MainActor
private func withCleanDefaults(_ body: @MainActor () async throws -> Void) async rethrows {
    UserDefaults.standard.removeObject(forKey: "historyRange")
    defer { UserDefaults.standard.removeObject(forKey: "historyRange") }
    try await body()
}

@MainActor
@Test func backfillReadsOnlyTheChosenRange() async throws {
    try await withCleanDefaults {
        let source = RecordingSource()
        let model = try await signedIn(source)
        #expect(model.historyRange == .all)

        model.historyRange = .quarter
        await model.startBackfill()

        #expect(source.pageJQLs == ["assignee = currentUser() AND updated >= -90d"])
    }
}

@MainActor
@Test func theRangeSurvivesARestart() async throws {
    try await withCleanDefaults {
        let first = try makeModel()
        first.historyRange = .year

        let second = try makeModel()
        #expect(second.historyRange == .year)
    }
}

/// 누르기 전에 보는 건수는 백필이 진행률에 쓰는 총계와 **같은 질문**이어야 한다.
@MainActor
@Test func theEstimateAsksTheSameQuestionAsTheBackfill() async throws {
    try await withCleanDefaults {
        let source = RecordingSource()
        source.count = 1_240
        let model = try await signedIn(source)
        model.historyRange = .halfYear

        await model.estimateHistoryScope()

        #expect(model.historyScopeEstimate == .approximately(1_240))
        #expect(source.countJQLs == [HistoryRange.halfYear.backfillJQL])
    }
}

@MainActor
@Test func aFailedEstimateSaysSoInsteadOfLyingWithZero() async throws {
    try await withCleanDefaults {
        let source = RecordingSource()
        let model = try await signedIn(source)

        await model.estimateHistoryScope()

        #expect(model.historyScopeEstimate == .unavailable)
    }
}

/// 범위를 바꾸면 옛 범위의 건수는 지워진다 — 새 범위 옆에 남으면 무엇을 세는지 알 수 없다.
@MainActor
@Test func changingTheRangeDropsTheOldEstimate() async throws {
    try await withCleanDefaults {
        let source = RecordingSource()
        source.count = 7
        let model = try await signedIn(source)
        await model.estimateHistoryScope()
        #expect(model.historyScopeEstimate == .approximately(7))

        model.historyRange = .quarter
        #expect(model.historyScopeEstimate == nil)

        // 같은 값을 다시 넣는 것은 변화가 아니다.
        await model.estimateHistoryScope()
        model.historyRange = .quarter
        #expect(model.historyScopeEstimate == .approximately(7))
    }
}

@MainActor
@Test func signOutForgetsTheEstimateButNotTheRange() async throws {
    try await withCleanDefaults {
        let source = RecordingSource()
        source.count = 7
        let model = try await signedIn(source)
        model.historyRange = .year
        await model.estimateHistoryScope()

        await model.signOut()

        #expect(model.historyScopeEstimate == nil)
        // 범위는 사이트 주소처럼 "나를 잊어라"가 아닌 선택이다.
        #expect(model.historyRange == .year)
    }
}
