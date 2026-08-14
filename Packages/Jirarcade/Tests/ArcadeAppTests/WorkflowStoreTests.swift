import Testing
import Foundation
import ArcadeCore
@testable import ArcadeApp

/// 테스트마다 격리된 임시 디렉터리를 만들고, 블록이 끝나면 지운다.
///
/// 정리하지 않으면 `swift test`를 돌릴 때마다 임시 디렉터리가 하나씩 쌓인다 —
/// 이 정리를 넣기 전 실제로 230개가 남아 있었다. 테스트가 남기는 부산물은
/// 실패를 만들지는 않지만, 디스크를 조금씩 갉아먹고 "이 프로젝트의 테스트는
/// 뒤처리를 안 한다"는 선례가 된다.
private func withTempDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("jirarcade-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

@Test func savedMappingComesBack() throws {
    try withTempDirectory { dir in
        let store = FileWorkflowStore(directory: dir)
        let map = WorkflowMap(statusToStage: ["To Do": .backlog, "Done": .done])
        try store.save(map)
        #expect(try store.load() == map)
    }
}

@Test func missingFileReturnsNil() throws {
    try withTempDirectory { dir in
        // throwing 호출을 `#expect` 밖으로 빼야 `try`가 실제 throwing 표현식에 붙는다.
        // 매크로 안에 두면 컴파일러가 클로저를 non-throwing으로 추론해 경고가 난다.
        let loaded = try FileWorkflowStore(directory: dir).load()
        #expect(loaded == nil)
    }
}

@Test func savingTwiceReplaces() throws {
    try withTempDirectory { dir in
        let store = FileWorkflowStore(directory: dir)
        try store.save(WorkflowMap(statusToStage: ["To Do": .backlog]))
        try store.save(WorkflowMap(statusToStage: ["Done": .done]))
        #expect(try store.load()?.statusToStage.count == 1)
        #expect(try store.load()?.stage(for: "Done") == .done)
    }
}

@Test func corruptedFileThrowsRatherThanReturningEmpty() throws {
    try withTempDirectory { dir in
        let store = FileWorkflowStore(directory: dir)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("workflow.json"))
        #expect(throws: (any Error).self) { try store.load() }
    }
}

@Test func nonAsciiStatusNamesSurvive() throws {
    try withTempDirectory { dir in
        let store = FileWorkflowStore(directory: dir)
        let map = WorkflowMap(statusToStage: ["진행 중": .active, "완료": .done])
        try store.save(map)
        #expect(try store.load() == map)
    }
}
