import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

private var utc: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private func loadFixture() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "sample-issues", withExtension: "json"))
    return try Data(contentsOf: url)
}

@Test func fixtureDecodesFourIssuesAndOneFailure() throws {
    let page = try JiraSearchResponse.decode(try loadFixture())
    #expect(page.issues.count == 4)
    #expect(page.failures.count == 1)
}

@MainActor
@Test func fullPipelineProducesEventsAndScore() async throws {
    let page = try JiraSearchResponse.decode(try loadFixture())
    let issues = page.issues.map(ObservedIssue.init)

    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = FixedSource(issues: issues)
    let engine = SyncEngine(source: source, store: store, rules: .default,
                            workflow: demoWorkflow, calendar: utc)

    let outcome = try await engine.sync(jql: "assignee = currentUser()",
                                        now: iso("2026-08-12T09:00:00Z"))

    #expect(outcome.newEvents.count == 4)
    #expect(outcome.summary.level >= 1)
}

@Test func hygieneOnFixtureReflectsRealStatusNames() throws {
    let page = try JiraSearchResponse.decode(try loadFixture())
    let issues = page.issues.map(ObservedIssue.init)
    let report = HygieneCalculator(rules: .default, workflow: demoWorkflow, calendar: utc)
        .evaluate(issues, now: iso("2026-08-12T09:00:00Z"))

    #expect(report.wipCount == 1, "In Progress은 DEMO-9613 한 건이다")
    #expect(report.wipPenalty == 0, "WIP 한도 이하이므로 감점 없음")
}

private struct FixedSource: IssueSource {
    let issues: [ObservedIssue]
    func fetchAssignedIssues(jql: String) async throws -> [ObservedIssue] { issues }
}
