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

/// `SyncSpy`와 별개로 둔다 — `SyncSpy`는 절대 진짜로 suspend하지 않는 것에
/// 기존 테스트들의 순서 보장이 의존하고 있어서, 여기에 suspend를 넣으면
/// 그 테스트들이 무엇을 검증하는지 달라진다.
/// 이 스파이는 `perform()` 안에서 실제로 suspend해서 두 `requestSync` 호출이
/// 진짜로 겹칠 기회를 만든다.
@MainActor
private final class SuspendingSpy {
    private(set) var calls = 0
    func perform() async throws {
        await Task.yield()
        await Task.yield()
        calls += 1
    }
}

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

/// 이 테스트가 없으면 가드를 지워도 나머지 테스트가 전부 통과한다 — 위의 `SyncSpy`는
/// 실제로 suspend하지 않아서, 순차적으로 `await`하는 다른 테스트들에서는
/// 두 `requestSync` 호출이 애초에 겹칠 기회가 없기 때문이다.
/// 이 테스트만 `SuspendingSpy`로 진짜 suspend를 일으키고 `async let`으로
/// 두 요청을 실제로 겹치게 만들어, `isSyncing` 가드가 하는 일을 직접 검증한다.
@MainActor
@Test func overlappingRequestsRunOnlyOnce() async {
    let spy = SuspendingSpy()
    let scheduler = SyncScheduler(
        settings: .default,
        clock: { iso("2026-08-14T09:00:00Z") },
        sleep: { _ in },
        perform: { try await spy.perform() }
    )

    async let first: Void = scheduler.requestSync(reason: .manual)
    async let second: Void = scheduler.requestSync(reason: .manual)
    _ = await (first, second)

    #expect(spy.calls == 1, "겹치는 두 번째 요청은 첫 번째가 끝날 때까지 무시되어야 한다")
}
