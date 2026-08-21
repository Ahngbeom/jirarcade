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

/// 미완료 run만 버린다. 완료된 run은 이력이라 남아야 한다 —
/// 실패로 끝난 백필을 다시 시도했을 때 `lastBackfillFailure()`가 사유를 잃으면
/// 설정 화면에서 왜 실패했는지 알 수 없다.
@MainActor
@Test func startingANewBackfillKeepsFinishedRuns() throws {
    let store = try makeStore()
    let start = iso("2026-08-13T09:00:00Z")

    let failed = try store.beginBackfill(jql: "q1", at: start, totalIssueCount: 10)
    try store.finishBackfill(failed, at: start.addingTimeInterval(60), failure: "offline")

    _ = try store.beginBackfill(jql: "q2", at: start.addingTimeInterval(120), totalIssueCount: 10)

    let failure = try store.lastBackfillFailure()
    #expect(failure == "offline", "새 run을 시작해도 완료된 run은 이력으로 남는다")
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

/// `lastBackfillFailure()`가 보는 것은 **가장 마지막에 끝난** run이다.
/// 옵셔널 `finishedAt`으로 정렬하므로, 아직 끝나지 않은 run이 nil로 섞여 들어와
/// 최근 것으로 뽑히지 않는지도 함께 고정한다 — 그러면 실패가 조용히 사라진다.
@MainActor
@Test func lastBackfillFailureLooksAtTheMostRecentlyFinishedRun() throws {
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
