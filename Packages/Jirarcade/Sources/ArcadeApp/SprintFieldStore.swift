import Foundation

/// 스프린트 커스텀 필드의 ID를 기억한다.
///
/// `WorkflowStore`에 얹지 않는 이유: 그 프로토콜은 이미 사용자 매핑과 백필 폴백을 함께
/// 떠안고 있고, history-backfill 후속 항목 §5.9가 "구현이 늘면 별도 프로토콜로 쪼개는 편이
/// 낫다"고 지적해 두었다. 스프린트 필드 ID는 워크플로와 아무 관계가 없으므로 처음부터 따로 둔다.
public protocol SprintFieldStore: Sendable {
    func load() throws -> String?
    func save(_ id: String) throws
    /// 계정이 바뀔 때 부른다. 다른 테넌트의 필드 ID는 무의미하다.
    func clear() throws
}

/// 앱 지원 디렉터리의 JSON 파일. `FileWorkflowStore`와 같은 자리, 다른 파일이다.
public struct FileSprintFieldStore: SprintFieldStore {
    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("sprint-field.json") }

    public init(directory: URL) { self.directory = directory }

    /// 기본 위치: ~/Library/Application Support/Jirarcade/
    public static func applicationSupport() throws -> FileSprintFieldStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Jirarcade", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return FileSprintFieldStore(directory: base)
    }

    private struct Stored: Codable { let fieldID: String }

    public func load() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Stored.self, from: data).fieldID
    }

    public func save(_ id: String) throws {
        let data = try JSONEncoder().encode(Stored(fieldID: id))
        try data.write(to: fileURL, options: .atomic)
    }

    /// 파일이 없어도 오류가 아니다 — 로그아웃 경로가 저장 여부와 무관하게 부른다.
    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// 테스트용. `InMemoryWorkflowStore`와 같은 패턴이다.
public final class InMemorySprintFieldStore: SprintFieldStore, @unchecked Sendable {
    private var stored: String?
    private let lock = NSLock()

    public init(seeded: String? = nil) { self.stored = seeded }

    public func load() throws -> String? { lock.withLock { stored } }
    public func save(_ id: String) throws { lock.withLock { stored = id } }
    public func clear() throws { lock.withLock { stored = nil } }
}
