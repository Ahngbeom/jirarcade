import Foundation
import ArcadeCore

public protocol WorkflowStore: Sendable {
    func load() throws -> WorkflowMap?
    func save(_ map: WorkflowMap) throws
}

/// 앱 지원 디렉터리의 JSON 파일. 사용자가 직접 열어 고칠 수 있어야 하므로
/// Keychain이 아니라 파일이다 — 조직 정보이지만 자격증명은 아니다.
public struct FileWorkflowStore: WorkflowStore {
    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("workflow.json") }

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
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(WorkflowMap.self, from: data)
    }

    public func save(_ map: WorkflowMap) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(map)
        try data.write(to: fileURL, options: .atomic)
    }
}

public final class InMemoryWorkflowStore: WorkflowStore, @unchecked Sendable {
    private var stored: WorkflowMap?
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
}
