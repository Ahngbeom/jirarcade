import Testing
import Foundation
@testable import ArcadeApp

/// 호출 횟수를 세고, 지시한 대로 성공/실패하는 스텁.
@MainActor
private final class SyncSpy {
    private(set) var calls = 0
    var nextError: (any Error)?
    /// 호출될 때마다 이 시간만큼 "걸린다"고 가정하고 clock을 밀어준다.
    var duration: Duration = .zero

    func perform() async throws {
        calls += 1
        if let nextError { throw nextError }
    }
}

private struct TestError: Error {}

@MainActor
private func makeScheduler(
    spy: SyncSpy, now: @escaping () -> Date
) -> SyncScheduler {
    SyncScheduler(
        settings: .default,
        clock: now,
        sleep: { _ in },                     // 즉시 반환 — 5분을 밀리초에 시뮬레이션
        perform: { try await spy.perform() }
    )
}

@MainActor
@Test func manualSyncRunsThePerformClosure() async {
    let spy = SyncSpy()
    let scheduler = makeScheduler(spy: spy, now: { iso("2026-08-14T09:00:00Z") })
    await scheduler.requestSync(reason: .manual)
    #expect(spy.calls == 1)
}

@MainActor
@Test func foregroundWithinCooldownIsSkipped() async {
    let spy = SyncSpy()
    var current = iso("2026-08-14T09:00:00Z")
    let scheduler = makeScheduler(spy: spy, now: { current })

    await scheduler.requestSync(reason: .manual)      // 1회
    current = current.addingTimeInterval(20)          // 20초 뒤 — 쿨다운(30초) 이내
    await scheduler.requestSync(reason: .foreground)

    #expect(spy.calls == 1, "쿨다운 안의 포그라운드 요청은 건너뛴다")
}

@MainActor
@Test func foregroundAfterCooldownRuns() async {
    let spy = SyncSpy()
    var current = iso("2026-08-14T09:00:00Z")
    let scheduler = makeScheduler(spy: spy, now: { current })

    await scheduler.requestSync(reason: .manual)
    current = current.addingTimeInterval(31)
    await scheduler.requestSync(reason: .foreground)

    #expect(spy.calls == 2)
}

@MainActor
@Test func manualIgnoresTheCooldown() async {
    let spy = SyncSpy()
    var current = iso("2026-08-14T09:00:00Z")
    let scheduler = makeScheduler(spy: spy, now: { current })

    await scheduler.requestSync(reason: .manual)
    current = current.addingTimeInterval(1)
    await scheduler.requestSync(reason: .manual)

    #expect(spy.calls == 2, "사용자가 명시적으로 눌렀으면 쿨다운을 무시한다")
}

@MainActor
@Test func failureIsRecordedButNotSurfacedUntilTheThirdOne() async {
    let spy = SyncSpy()
    spy.nextError = TestError()
    var current = iso("2026-08-14T09:00:00Z")
    let scheduler = makeScheduler(spy: spy, now: { current })

    for i in 1...3 {
        await scheduler.requestSync(reason: .manual)
        current = current.addingTimeInterval(60)
        #expect(scheduler.state.consecutiveFailures == i)
        #expect(scheduler.state.shouldSurfaceFailure == (i >= 3))
    }
}

@MainActor
@Test func successResetsTheFailureCount() async {
    let spy = SyncSpy()
    spy.nextError = TestError()
    var current = iso("2026-08-14T09:00:00Z")
    let scheduler = makeScheduler(spy: spy, now: { current })

    await scheduler.requestSync(reason: .manual)
    current = current.addingTimeInterval(60)
    #expect(scheduler.state.consecutiveFailures == 1)

    spy.nextError = nil
    await scheduler.requestSync(reason: .manual)
    #expect(scheduler.state.consecutiveFailures == 0)
    #expect(scheduler.state.shouldSurfaceFailure == false)
}

@MainActor
@Test func lastSyncTimeAdvancesOnSuccessOnly() async {
    let spy = SyncSpy()
    var current = iso("2026-08-14T09:00:00Z")
    let scheduler = makeScheduler(spy: spy, now: { current })

    await scheduler.requestSync(reason: .manual)
    let afterSuccess = scheduler.state.lastSyncAt

    spy.nextError = TestError()
    current = current.addingTimeInterval(60)
    await scheduler.requestSync(reason: .manual)

    #expect(scheduler.state.lastSyncAt == afterSuccess, "실패는 마지막 동기화 시각을 갱신하지 않는다")
}
