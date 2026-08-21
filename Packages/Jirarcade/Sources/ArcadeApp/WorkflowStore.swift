import Foundation
import ArcadeCore

public protocol WorkflowStore: Sendable {
    func load() throws -> WorkflowMap?
    func save(_ map: WorkflowMap) throws
    /// 백필이 statusCategory로 추정한 매핑. 사용자 매핑과 **분리해서** 저장한다 —
    /// 마법사가 "내가 정한 것"과 "앱이 추정한 것"을 구분해 보여줘야 하고,
    /// 사용자가 지정하면 폴백은 덮이는 게 아니라 밑에 깔린 채 남아야 한다.
    func loadFallbacks() throws -> WorkflowMap?
    func saveFallbacks(_ map: WorkflowMap) throws
}

/// 앱 지원 디렉터리의 JSON 파일. 사용자가 직접 열어 고칠 수 있어야 하므로
/// Keychain이 아니라 파일이다 — 조직 정보이지만 자격증명은 아니다.
public struct FileWorkflowStore: WorkflowStore {
    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("workflow.json") }
    private var fallbackURL: URL { directory.appendingPathComponent("workflow-fallbacks.json") }

    public init(directory: URL) { self.directory = directory }

    /// 기본 위치: ~/Library/Application Support/Jirarcade/
    public static func applicationSupport() throws -> FileWorkflowStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Jirarcade", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return FileWorkflowStore(directory: base)
    }

    public func load() throws -> WorkflowMap? {
        try read(from: fileURL)
    }

    public func save(_ map: WorkflowMap) throws {
        try write(map, to: fileURL)
    }

    public func loadFallbacks() throws -> WorkflowMap? {
        try read(from: fallbackURL)
    }

    public func saveFallbacks(_ map: WorkflowMap) throws {
        try write(map, to: fallbackURL)
    }

    private func read(from url: URL) throws -> WorkflowMap? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WorkflowMap.self, from: data)
    }

    private func write(_ map: WorkflowMap, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(map)
        try data.write(to: url, options: .atomic)
    }
}

public final class InMemoryWorkflowStore: WorkflowStore, @unchecked Sendable {
    private var stored: WorkflowMap?
    private var storedFallbacks: WorkflowMap?
    private let lock = NSLock()

    /// 설정하면 `load()`가 저장된 값 대신 이 에러를 던진다.
    public var loadError: (any Error)?
    /// 설정하면 `save(_:)`가 값을 저장하지 않고 이 에러를 던진다.
    /// `InMemoryCredentialStore`와 대칭이다 — `confirmMapping`의 저장 실패 처리를
    /// 테스트하려면 이 훅이 있어야 한다.
    public var saveError: (any Error)?

    public init(seeded: WorkflowMap? = nil) { self.stored = seeded }

    public func load() throws -> WorkflowMap? {
        if let loadError { throw loadError }
        return lock.withLock { stored }
    }

    public func save(_ map: WorkflowMap) throws {
        if let saveError { throw saveError }
        lock.withLock { stored = map }
    }

    /// `loadError`/`saveError` 훅은 사용자 매핑 경로에만 적용한다 — 폴백 저장 실패를
    /// 따로 시험할 필요가 아직 없고, 공유하면 기존 테스트의 의미가 바뀐다.
    public func loadFallbacks() throws -> WorkflowMap? {
        lock.withLock { storedFallbacks }
    }

    public func saveFallbacks(_ map: WorkflowMap) throws {
        lock.withLock { storedFallbacks = map }
    }
}
