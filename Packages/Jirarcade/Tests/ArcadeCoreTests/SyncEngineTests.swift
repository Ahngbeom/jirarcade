import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

private var utc: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

/// 호출 순서대로 미리 정한 결과를 돌려주는 테스트용 소스.
private final class ScriptedSource: IssueSource, @unchecked Sendable {
    private var pages: [[ObservedIssue]]
    /// 각 호출에서 돌려줄 디코딩 실패 건수. 비어 있으면 0으로 취급한다.
    private var decodingFailures: [Int]
    var error: (any Error)?
    private(set) var callCount = 0

    init(_ pages: [[ObservedIssue]], decodingFailures: [Int] = []) {
        self.pages = pages
        self.decodingFailures = decodingFailures
    }

    func fetchAssignedIssues(jql: String) async throws -> FetchResult {
        callCount += 1
        if let error { throw error }
        let issues = pages.isEmpty ? [] : pages.removeFirst()
        let failures = decodingFailures.isEmpty ? 0 : decodingFailures.removeFirst()
        return FetchResult(issues: issues, decodingFailures: failures)
    }
}

@MainActor
private func makeEngine(_ source: ScriptedSource) throws -> (SyncEngine, ArcadeStore) {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let engine = SyncEngine(source: source, store: store, rules: .default,
                            workflow: demoWorkflow, calendar: utc)
    return (engine, store)
}

@MainActor
@Test func firstSyncRecordsAppearedEventsForEveryIssue() async throws {
    let source = ScriptedSource([[issue(key: "DEMO-1", status: "To Do"),
                                  issue(key: "DEMO-2", status: "In Progress")]])
    let (engine, store) = try makeEngine(source)

    let outcome = try await engine.sync(jql: "assignee = currentUser()",
                                        now: iso("2026-08-12T09:00:00Z"))

    #expect(outcome.newEvents.count == 2)
    #expect(outcome.newEvents.allSatisfy { $0.kind == .appeared })
    #expect(try store.loadMirror().count == 2)
}

@MainActor
@Test func secondSyncOnlyRecordsWhatChanged() async throws {
    let day1 = iso("2026-08-11T09:00:00Z")
    let day2 = iso("2026-08-12T09:00:00Z")
    let source = ScriptedSource([
        [issue(key: "DEMO-1", status: "To Do", updated: day1)],
        [issue(key: "DEMO-1", status: "In Progress", updated: day2)],
    ])
    let (engine, _) = try makeEngine(source)

    _ = try await engine.sync(jql: "q", now: day1)
    let second = try await engine.sync(jql: "q", now: day2)

    #expect(second.newEvents.map(\.kind) == [.statusChanged])
    #expect(second.newEvents[0].toStatus == "In Progress")
}

@MainActor
@Test func repeatedSyncWithNoChangesAddsNoEvents() async throws {
    let day = iso("2026-08-12T09:00:00Z")
    let same = issue(key: "DEMO-1", status: "In Progress", updated: day)
    let source = ScriptedSource([[same], [same]])
    let (engine, store) = try makeEngine(source)

    _ = try await engine.sync(jql: "q", now: day)
    let second = try await engine.sync(jql: "q", now: day)

    #expect(second.newEvents.isEmpty)
    #expect(try store.loadEvents().count == 1, "첫 동기화의 appeared 1건만 남는다")
}

@MainActor
@Test func summaryReflectsTheWholeEventLog() async throws {
    let day1 = iso("2026-08-11T09:00:00Z")
    let day2 = iso("2026-08-12T09:00:00Z")
    let source = ScriptedSource([
        [issue(key: "DEMO-1", status: "To Do", updated: day1)],
        [issue(key: "DEMO-1", status: "In Progress", updated: day2)],
    ])
    let (engine, _) = try makeEngine(source)

    _ = try await engine.sync(jql: "q", now: day1)
    let second = try await engine.sync(jql: "q", now: day2)

    #expect(second.summary.totalXP > 0)
    #expect(second.summary.level >= 1)
}

/// 마감 전 완료로 얻은 XP는 티켓이 조회 결과에서 사라져도 남아야 한다.
///
/// 실측된 증상: `totalXP` 202 → 68. 마감 보너스가 미러의 `dueDate`를 보던 탓에,
/// 완료된 티켓이 JQL(`statusCategory != Done`)에서 빠지는 **다음 폴링**에 보너스가 증발했다.
/// 덜 주는 것보다 나쁘다 — 축하 직후 레벨 게이지가 뒤로 간다.
@MainActor
@Test func completionXPSurvivesTheTicketLeavingTheQuery() async throws {
    let day1 = iso("2026-08-12T09:00:00Z")
    let day2 = iso("2026-08-12T10:00:00Z")
    let day3 = iso("2026-08-12T10:05:00Z")
    let due = iso("2026-08-20T00:00:00Z")

    let source = ScriptedSource([
        [issue(key: "DEMO-1", status: "Verifying", due: due,
               updated: day1.addingTimeInterval(-days(10)))],
        [issue(key: "DEMO-1", status: "Done", due: due, updated: day2)],
        [],   // 완료됐으므로 JQL에서 빠진다
    ])
    let (engine, _) = try makeEngine(source)

    _ = try await engine.sync(jql: "q", now: day1)
    let completed = try await engine.sync(jql: "q", now: day2)
    let afterVanish = try await engine.sync(jql: "q", now: day3)

    func eventXP(_ outcome: SyncOutcome) -> Int {
        outcome.summary.totalXP - outcome.summary.hygieneBonusXP
    }

    #expect(eventXP(completed) > 0)
    #expect(eventXP(afterVanish) == eventXP(completed), "티켓이 사라져도 준 XP를 뺏지 않는다")
}

/// 페치가 비면 미러가 비워지고 `vanished`는 한 번만 나온다.
/// 미러를 보존하면 다음 diff가 같은 이벤트를 또 만들어, 삭제하지 않기로 한 로그에
/// 5분마다 미러 크기만큼 쓰레기가 쌓인다.
@MainActor
@Test func anEmptyFetchProducesVanishedOnlyOnce() async throws {
    let day = iso("2026-08-12T09:00:00Z")
    let source = ScriptedSource([[issue(key: "DEMO-1", status: "In Progress", updated: day)]])
    let (engine, store) = try makeEngine(source)

    _ = try await engine.sync(jql: "q", now: day)

    let second = try await engine.sync(jql: "q", now: day.addingTimeInterval(300))
    #expect(second.newEvents.map(\.kind) == [.vanished])
    #expect(try store.loadMirror().isEmpty)

    let third = try await engine.sync(jql: "q", now: day.addingTimeInterval(600))
    #expect(third.newEvents.isEmpty, "미러가 비었으므로 다시 만들 vanished가 없다")
    #expect(try store.loadEvents().count == 2, "appeared 1건 + vanished 1건")
}

/// 페치가 성공했는데 0건인 상황은 "깨끗한 성공"이 아니다.
/// 전량 디코딩 실패는 예외가 아니라 빈 배열로 나타나므로 여기서 잡지 않으면 흔적이 없다.
@MainActor
@Test func aZeroIssueFetchIsRecordedInTheSyncRun() async throws {
    let day = iso("2026-08-12T09:00:00Z")
    let source = ScriptedSource([[issue(key: "DEMO-1", status: "In Progress", updated: day)]])
    let (engine, store) = try makeEngine(source)

    _ = try await engine.sync(jql: "q", now: day)
    _ = try await engine.sync(jql: "q", now: day.addingTimeInterval(300))

    let runs = try store.loadSyncRuns()
    #expect(runs.count == 2)
    #expect(runs[0].note == nil)
    let note = try #require(runs[1].note)
    #expect(note.contains("0건"))
    #expect(runs[1].observedIssueCount == 0)
    #expect(runs[1].failureMessage == nil, "0건은 실패가 아니다")
}

/// 디코딩 실패는 성공한 이슈가 있어도 흔적을 남겨야 한다 — 일부만 실패해도 조용히
/// 사라지면 다음에 왜 개수가 안 맞는지 추적할 수 없다.
@MainActor
@Test func decodingFailuresAreNotedEvenWhenSomeIssuesSucceed() async throws {
    let day = iso("2026-08-12T09:00:00Z")
    let source = ScriptedSource(
        [[issue(key: "DEMO-1", status: "To Do"), issue(key: "DEMO-2", status: "In Progress")]],
        decodingFailures: [3]
    )
    let (engine, store) = try makeEngine(source)

    _ = try await engine.sync(jql: "q", now: day)

    let runs = try store.loadSyncRuns()
    let note = try #require(runs[0].note)
    #expect(note.contains("3"))
    #expect(note.contains("2"), "반영된 건수도 함께 드러나야 한다")
    #expect(runs[0].failureMessage == nil, "디코딩 실패는 동기화 자체의 실패가 아니다")
}

/// 조회 결과가 0건이면서 디코딩 실패까지 있는 것 — 전량 디코딩 실패 — 은 이 변경이
/// 존재하는 이유 그 자체다. note가 두 사실(0건, 실패 건수)을 모두 담아야 하고,
/// 그럼에도 동기화 자체는 성공으로 기록되어 observationDayCount에 계속 잡혀야 한다.
@MainActor
@Test func aFullyFailedFetchNotesBothZeroIssuesAndTheFailureCount() async throws {
    let day = iso("2026-08-12T09:00:00Z")
    let source = ScriptedSource([[]], decodingFailures: [5])
    let (engine, store) = try makeEngine(source)

    _ = try await engine.sync(jql: "q", now: day)

    let runs = try store.loadSyncRuns()
    let note = try #require(runs[0].note)
    #expect(note.contains("5"), "실패 건수가 드러나야 한다")
    #expect(note.contains("0"), "반영된 게 0건이라는 사실도 드러나야 한다")
    #expect(runs[0].failureMessage == nil, "전량 실패여도 페치 자체는 성공이다")
    #expect(runs[0].observedIssueCount == 0)
    #expect(try store.observationDayCount(now: day, calendar: utc) == 1,
           "성공으로 기록되어야 관측 일수에 잡힌다")
}

/// 메모를 `failureMessage`에 적으면 그 동기화가 `observationDayCount`의 술어에서
/// 배제되어 "성공했는데 관측 0일차"가 된다. 하필 첫 동기화에서 벌어지면 이후 영구히 어긋난다.
@MainActor
@Test func anEmptyFirstSyncStillCountsAsDayOne() async throws {
    let day1 = iso("2026-08-10T09:00:00Z")
    let source = ScriptedSource([[]])   // 신규 사용자 / 할 일을 다 끝낸 상태
    let (engine, store) = try makeEngine(source)

    _ = try await engine.sync(jql: "q", now: day1)

    #expect(try store.observationDayCount(now: day1, calendar: utc) == 1)
    #expect(try store.observationDayCount(now: day1.addingTimeInterval(days(4)),
                                          calendar: utc) == 5)
}

@MainActor
@Test func failedSyncLeavesTheMirrorIntactAndRethrows() async throws {
    let day = iso("2026-08-12T09:00:00Z")
    let source = ScriptedSource([[issue(key: "DEMO-1", status: "In Progress", updated: day)]])
    let (engine, store) = try makeEngine(source)
    _ = try await engine.sync(jql: "q", now: day)

    source.error = JiraError.offline
    await #expect(throws: JiraError.offline) {
        _ = try await engine.sync(jql: "q", now: day.addingTimeInterval(300))
    }

    #expect(try store.loadMirror().count == 1, "실패해도 마지막 미러는 남는다")
}
