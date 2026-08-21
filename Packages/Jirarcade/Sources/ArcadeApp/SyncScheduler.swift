import Foundation

public enum SyncReason: Sendable, Equatable {
    case timer, foreground, manual
}

/// 언제 동기화를 부를지 결정한다. 실제 동기화는 주입된 클로저가 한다 —
/// 이 타입은 스케줄만 알고 SyncEngine을 모른다.
@MainActor
public final class SyncScheduler {
    public struct State: Sendable, Equatable {
        public internal(set) var consecutiveFailures = 0
        public internal(set) var lastSyncAt: Date?
        public internal(set) var lastFailure: String?

        /// 연속 실패가 임계에 닿았을 때만 UI에 보여준다.
        /// 일시적 끊김마다 경고를 띄우면 사용자는 경고를 무시하는 법부터 배운다.
        public internal(set) var shouldSurfaceFailure = false
    }

    public private(set) var state = State()

    private let settings: AppSettings
    private let clock: () -> Date
    private let sleep: (Duration) async throws -> Void
    private let perform: () async throws -> Void

    private var isSyncing = false
    private var loopTask: Task<Void, Never>?

    /// 주기 동기화 루프가 살아 있는가. 백필처럼 동기화를 잠시 멈추는 쪽이,
    /// 끝난 뒤 **원래 돌고 있었을 때만** 되살리려면 이 값을 먼저 봐야 한다 —
    /// 무조건 `start()`하면 사용자가 꺼둔 동기화가 백필 때문에 켜진다.
    public var isRunning: Bool { loopTask != nil }

    public init(
        settings: AppSettings = .default,
        clock: @escaping () -> Date,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        perform: @escaping () async throws -> Void
    ) {
        self.settings = settings
        self.clock = clock
        self.sleep = sleep
        self.perform = perform
    }

    deinit { loopTask?.cancel() }

    /// 동기화를 요청한다. 이미 돌고 있거나 쿨다운에 걸리면 조용히 무시한다.
    public func requestSync(reason: SyncReason) async {
        guard !isSyncing else { return }
        guard shouldRun(reason: reason) else { return }

        isSyncing = true
        defer { isSyncing = false }

        do {
            try await perform()
            state.consecutiveFailures = 0
            state.lastFailure = nil
            state.shouldSurfaceFailure = false
            state.lastSyncAt = clock()
        } catch {
            state.consecutiveFailures += 1
            state.lastFailure = String(describing: error)
            state.shouldSurfaceFailure =
                state.consecutiveFailures >= settings.failuresBeforeSurfacing
        }
    }

    /// 포그라운드 복귀는 쿨다운을 지킨다. 수동과 타이머는 지키지 않는다 —
    /// 수동은 사용자가 명시적으로 원한 것이고, 타이머는 이미 간격만큼 기다렸다.
    private func shouldRun(reason: SyncReason) -> Bool {
        guard reason == .foreground, let last = state.lastSyncAt else { return true }
        let elapsed = clock().timeIntervalSince(last)
        return elapsed >= Double(settings.foregroundCooldown.components.seconds)
    }

    /// 주기 동기화를 시작한다. 실패가 쌓이면 백오프만큼 더 기다린다.
    public func start() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let base = self.settings.syncInterval
                let extra = self.settings.backoffDelay(
                    afterConsecutiveFailures: self.state.consecutiveFailures
                )
                try? await self.sleep(base + extra)
                guard !Task.isCancelled else { return }
                await self.requestSync(reason: .timer)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }
}
