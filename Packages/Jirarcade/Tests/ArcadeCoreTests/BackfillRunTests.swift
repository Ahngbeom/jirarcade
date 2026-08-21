import Testing
import Foundation
import SwiftData
@testable import ArcadeCore

@MainActor
private func makeStore() throws -> ArcadeStore {
    ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
}

@MainActor
@Test func backfillProgressSurvivesRestart() throws {
    let store = try makeStore()
    let start = iso("2026-08-13T09:00:00Z")

    let id = try store.beginBackfill(jql: "assignee = currentUser()", at: start,
                                     totalIssueCount: 1263)
    try store.advanceBackfill(id, nextPageToken: "tok-3", processedIssueCount: 300,
                              discovered: ["Merged to Staging"], partiallyRestored: [])

    let resumable = try #require(try store.resumableBackfill())
    #expect(resumable.nextPageToken == "tok-3")
    #expect(resumable.processedIssueCount == 300)
    #expect(resumable.totalIssueCount == 1263)
    #expect(resumable.jql == "assignee = currentUser()")
}

/// 끝난 백필은 재개 대상이 아니다.
@MainActor
@Test func finishedBackfillIsNotResumable() throws {
    let store = try makeStore()
    let start = iso("2026-08-13T09:00:00Z")
    let id = try store.beginBackfill(jql: "q", at: start, totalIssueCount: 10)
    try store.finishBackfill(id, at: start.addingTimeInterval(60), failure: nil)
    // throwing 호출을 #expect 안에 두면 클로저가 non-throwing으로 추론돼 경고가 난다.
    let resumable = try store.resumableBackfill()
    #expect(resumable == nil)
}

/// 실패로 끝난 백필도 재개 대상이 아니다 — 사용자가 다시 누르면 새 run이 시작된다.
/// 실패 사실은 기록으로 남아 설정 화면이 보여준다.
@MainActor
@Test func failedBackfillIsRecordedButNotResumable() throws {
    let store = try makeStore()
    let start = iso("2026-08-13T09:00:00Z")
    let id = try store.beginBackfill(jql: "q", at: start, totalIssueCount: 10)
    try store.finishBackfill(id, at: start.addingTimeInterval(5), failure: "offline")

    let resumable = try store.resumableBackfill()
    #expect(resumable == nil)
    let failure = try store.lastBackfillFailure()
    #expect(failure == "offline")
}

/// 이어서 하지 않고 새로 시작하면 이전 미완료 run은 버려진 것이다. 남겨두면
/// resumableBackfill()이 계속 그걸 집어 "이어서 하시겠습니까"가 영원히 뜬다.
@MainActor
@Test func startingANewBackfillDiscardsTheAbandonedOne() throws {
    let store = try makeStore()
    let first = iso("2026-08-13T09:00:00Z")

    let abandoned = try store.beginBackfill(jql: "old", at: first, totalIssueCount: 100)
    try store.advanceBackfill(abandoned, nextPageToken: "tok-1", processedIssueCount: 50,
                              discovered: [], partiallyRestored: [])

    _ = try store.beginBackfill(jql: "new", at: first.addingTimeInterval(3600),
                                totalIssueCount: 200)

    let resumable = try #require(try store.resumableBackfill())
    #expect(resumable.jql == "new")
    #expect(resumable.nextPageToken == nil, "새 run은 처음부터 시작한다")
    #expect(resumable.processedIssueCount == 0)

    // 새 run이 항상 더 나중이라 위 세 어서션은 옛 run이 남아 있어도 참이다.
    // 실제로 삭제됐는지는 옛 id를 갱신해 봐야만 드러난다.
    #expect(throws: ArcadeStoreError.backfillRunNotFound) {
        try store.advanceBackfill(abandoned, nextPageToken: "tok-2", processedIssueCount: 60,
                                  discovered: [], partiallyRestored: [])
    }
}

/// 미완료 run만 버린다. 완료된 run은 이력이라 남아야 한다.
///
/// `lastBackfillFailure()`로 보지 않는 이유: 그건 가장 최근에 **시작한** run을 보므로
/// 방금 시작한 q2(아직 실패하지 않음)를 집는다. 여기서 확인할 것은 q1 레코드가
/// 지워지지 않았다는 사실 자체다.
@MainActor
@Test func startingANewBackfillKeepsFinishedRuns() throws {
    let container = try ArcadeStore.makeInMemoryContainer()
    let store = ArcadeStore(container: container)
    let start = iso("2026-08-13T09:00:00Z")

    let failed = try store.beginBackfill(jql: "q1", at: start, totalIssueCount: 10)
    try store.finishBackfill(failed, at: start.addingTimeInterval(60), failure: "offline")

    _ = try store.beginBackfill(jql: "q2", at: start.addingTimeInterval(120), totalIssueCount: 10)

    let runs = try container.mainContext.fetch(FetchDescriptor<BackfillRun>())
    let kept = try #require(runs.first { $0.jql == "q1" })
    #expect(kept.failureMessage == "offline", "새 run을 시작해도 완료된 run은 이력으로 남는다")
}

/// 실패 사유를 적어도 run은 미완료로 남는다 — 재개 지점을 잃지 않는다.
/// `finishBackfill(failure:)`로 닫으면 여기까지 받은 1,000여 건의 진행이 버려진다.
@MainActor
@Test func recordingAFailureKeepsTheRunResumable() throws {
    let store = try makeStore()
    let start = iso("2026-08-13T09:00:00Z")
    let id = try store.beginBackfill(jql: "q", at: start, totalIssueCount: 1263)
    try store.advanceBackfill(id, nextPageToken: "tok-3", processedIssueCount: 300,
                              discovered: [], partiallyRestored: [])

    try store.recordBackfillFailure(id, message: "URLError")

    let resumable = try #require(try store.resumableBackfill())
    #expect(resumable.nextPageToken == "tok-3")
    let failure = try store.lastBackfillFailure()
    #expect(failure == "URLError", "끝나지 않은 run의 사유도 보여야 한다")
}

/// 없는 run에 사유를 적으려 하면 던진다. 조용히 return하면 실패가 흔적 없이 사라지고
/// 설정 화면은 아무 말도 하지 않는다.
@MainActor
@Test func recordingAFailureOnAMissingRunThrows() throws {
    let store = try makeStore()
    let id = try store.beginBackfill(jql: "q", at: iso("2026-08-13T09:00:00Z"),
                                     totalIssueCount: 10)

    let other = try makeStore()   // 다른 컨테이너 — 이 id는 여기에 없다
    #expect(throws: ArcadeStoreError.backfillRunNotFound) {
        try other.recordBackfillFailure(id, message: "URLError")
    }
}

/// 미완료 run이 여러 개면 가장 최근에 시작한 것을 집는다.
/// `beginBackfill`이 미완료 run을 지우므로 정상 흐름에서는 하나뿐이지만,
/// 그 불변식이 깨졌을 때 옛 run을 이어받지 않도록 정렬 의도 자체를 고정한다.
@MainActor
@Test func resumableBackfillPicksTheMostRecentlyStartedRun() throws {
    let container = try ArcadeStore.makeInMemoryContainer()
    let store = ArcadeStore(container: container)
    let start = iso("2026-08-13T09:00:00Z")

    // beginBackfill은 미완료 run을 지우므로, 두 개를 공존시키려면 직접 넣어야 한다.
    let context = container.mainContext
    context.insert(BackfillRun(startedAt: start, jql: "older", totalIssueCount: 10))
    context.insert(BackfillRun(startedAt: start.addingTimeInterval(3600),
                               jql: "newer", totalIssueCount: 20))
    try context.save()

    let resumable = try #require(try store.resumableBackfill())
    #expect(resumable.jql == "newer")
}

/// 계정이 바뀌면 백필 진행도 함께 버린다. 남으면 새 계정에서 "이어서 불러오기"가 뜨고,
/// 누르는 순간 옛 계정의 jql·페이지 커서로 이 계정의 백필을 이어간다.
@MainActor
@Test func resetDiscardsBackfillProgress() throws {
    let store = try makeStore()
    let start = iso("2026-08-13T09:00:00Z")

    let failed = try store.beginBackfill(jql: "q", at: start, totalIssueCount: 10)
    try store.finishBackfill(failed, at: start.addingTimeInterval(60), failure: "offline")

    let id = try store.beginBackfill(jql: "assignee = currentUser()",
                                     at: start.addingTimeInterval(120), totalIssueCount: 1263)
    try store.advanceBackfill(id, nextPageToken: "tok-3", processedIssueCount: 300,
                              discovered: ["Merged to Staging"], partiallyRestored: ["MPT-1"])

    try store.reset()

    let resumable = try store.resumableBackfill()
    #expect(resumable == nil, "옛 계정의 페이지 커서를 새 계정이 이어받으면 안 된다")
    let failure = try store.lastBackfillFailure()
    #expect(failure == nil, "완료된 백필 이력도 계정과 함께 사라진다")
}

/// 없는 run을 갱신하려 하면 던진다. 조용히 return하면 진행 상황이 저장되지 않은 채
/// 호출자는 성공으로 알고, 재개 시 1,000여 건을 처음부터 다시 훑는다.
@MainActor
@Test func advancingAMissingRunThrows() throws {
    let store = try makeStore()
    let id = try store.beginBackfill(jql: "q", at: iso("2026-08-13T09:00:00Z"),
                                     totalIssueCount: 10)
    try store.finishBackfill(id, at: iso("2026-08-13T09:01:00Z"), failure: nil)

    let other = try makeStore()   // 다른 컨테이너 — 이 id는 여기에 없다
    #expect(throws: ArcadeStoreError.backfillRunNotFound) {
        try other.advanceBackfill(id, nextPageToken: "x", processedIssueCount: 1,
                                  discovered: [], partiallyRestored: [])
    }
}

/// 없는 run을 끝내려 하면 던진다. 조용히 return하면 그 run이 finishedAt == nil로
/// 영원히 남아 resumableBackfill()이 매번 "이어서 하시겠습니까"를 띄운다.
@MainActor
@Test func finishingAMissingRunThrows() throws {
    let store = try makeStore()
    let id = try store.beginBackfill(jql: "q", at: iso("2026-08-13T09:00:00Z"),
                                     totalIssueCount: 10)

    let other = try makeStore()   // 다른 컨테이너 — 이 id는 여기에 없다
    #expect(throws: ArcadeStoreError.backfillRunNotFound) {
        try other.finishBackfill(id, at: iso("2026-08-13T09:01:00Z"), failure: nil)
    }
}

/// 발견한 미매핑 상태와 부분 복원 티켓이 누적된다.
@MainActor
@Test func discoveriesAccumulateAcrossPages() throws {
    let store = try makeStore()
    let start = iso("2026-08-13T09:00:00Z")
    let id = try store.beginBackfill(jql: "q", at: start, totalIssueCount: 200)

    try store.advanceBackfill(id, nextPageToken: "a", processedIssueCount: 100,
                              discovered: ["Merged to Staging"], partiallyRestored: ["MPT-1"])
    try store.advanceBackfill(id, nextPageToken: "b", processedIssueCount: 200,
                              discovered: ["검수Done", "Merged to Staging"], partiallyRestored: ["MPT-2"])

    // 저장 시점에 정렬하므로 읽을 때마다 순서가 같다. Set을 그대로 Array로 만들면
    // 순서가 비결정적이라 매핑 마법사의 후보 목록이 열 때마다 뒤바뀐다.
    let snapshot = try #require(try store.resumableBackfill())
    #expect(snapshot.discovered == ["Merged to Staging", "검수Done"].sorted())
    #expect(snapshot.partiallyRestored == ["MPT-1", "MPT-2"])
}

/// `lastBackfillFailure()`가 보는 것은 **가장 최근에 시작한** run이다.
/// 나중에 성공했으면 옛 실패는 더 이상 보이지 않고, 아직 끝나지 않은 run이 섞여도
/// 사유 없는 run은 사유 없음으로 읽힌다.
@MainActor
@Test func lastBackfillFailureLooksAtTheMostRecentlyStartedRun() throws {
    let store = try makeStore()
    let start = iso("2026-08-13T09:00:00Z")

    let older = try store.beginBackfill(jql: "q1", at: start, totalIssueCount: 10)
    try store.finishBackfill(older, at: start.addingTimeInterval(60), failure: "offline")
    let newer = try store.beginBackfill(jql: "q2", at: start.addingTimeInterval(120),
                                        totalIssueCount: 10)
    try store.finishBackfill(newer, at: start.addingTimeInterval(180), failure: nil)

    var failure = try store.lastBackfillFailure()
    #expect(failure == nil, "나중에 성공했으면 옛 실패는 더 이상 보이지 않는다")

    // 아직 끝나지 않은 run이 있어도 결과가 바뀌면 안 된다.
    _ = try store.beginBackfill(jql: "q3", at: start.addingTimeInterval(240),
                                totalIssueCount: 10)
    failure = try store.lastBackfillFailure()
    #expect(failure == nil)

    let failed = try store.beginBackfill(jql: "q4", at: start.addingTimeInterval(300),
                                         totalIssueCount: 10)
    try store.finishBackfill(failed, at: start.addingTimeInterval(360), failure: "rate limited")
    failure = try store.lastBackfillFailure()
    #expect(failure == "rate limited")
}

/// 발견 목록은 **모든 run의 합집합**이다.
///
/// 마지막 run 하나만 보면, 정상 완료된 백필이 발견한 상태를 그 뒤에 첫 페이지에서 실패한
/// run이 화면에서 통째로 지운다 — 고쳐야 할 추정은 그대로 채점되는데 마법사에는 행이
/// 뜨지 않는다. 데이터는 완료된 run에 남아 있으므로 문제는 조회 쪽이었다.
@MainActor
@Test func discoveriesFromEarlierRunsAreNotHiddenByALaterEmptyRun() throws {
    let store = try makeStore()
    let start = iso("2026-08-13T09:00:00Z")

    let completed = try store.beginBackfill(jql: "q", at: start, totalIssueCount: 100)
    try store.advanceBackfill(completed, nextPageToken: nil, processedIssueCount: 100,
                              discovered: ["Merged to Staging", "QA Done"],
                              partiallyRestored: [])
    try store.finishBackfill(completed, at: start.addingTimeInterval(600), failure: nil)

    // 사용자가 다시 눌렀지만 첫 페이지에서 실패했다 — 이 run의 발견은 0건이다.
    let retried = try store.beginBackfill(jql: "q", at: start.addingTimeInterval(3600),
                                          totalIssueCount: 100)
    try store.recordBackfillFailure(retried, message: "SyncFailure")

    #expect(try store.discoveredStatuses() == ["Merged to Staging", "QA Done"],
            "이전 run이 발견한 상태가 남아야 마법사에서 고칠 수 있다")
}

/// 여러 run의 발견이 겹쳐도 중복 없이, 정렬된 순서로 나온다 —
/// 순서가 흔들리면 마법사 후보 목록이 열 때마다 뒤바뀐다.
@MainActor
@Test func discoveredStatusesAreDeduplicatedAndSorted() throws {
    let store = try makeStore()
    let start = iso("2026-08-13T09:00:00Z")

    let first = try store.beginBackfill(jql: "q", at: start, totalIssueCount: 10)
    try store.advanceBackfill(first, nextPageToken: nil, processedIssueCount: 10,
                              discovered: ["QA Done", "Merged to Staging"], partiallyRestored: [])
    try store.finishBackfill(first, at: start.addingTimeInterval(60), failure: nil)

    let second = try store.beginBackfill(jql: "q", at: start.addingTimeInterval(120),
                                         totalIssueCount: 10)
    try store.advanceBackfill(second, nextPageToken: nil, processedIssueCount: 10,
                              discovered: ["Merged to Staging", "On Hold"], partiallyRestored: [])
    try store.finishBackfill(second, at: start.addingTimeInterval(180), failure: nil)

    #expect(try store.discoveredStatuses() == ["Merged to Staging", "On Hold", "QA Done"])
}
