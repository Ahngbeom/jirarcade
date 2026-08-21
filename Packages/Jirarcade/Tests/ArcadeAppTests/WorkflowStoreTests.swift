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

/// 폴백은 사용자 매핑과 따로 저장된다 — 마법사가 "내가 정한 것"과
/// "앱이 추정한 것"을 구분해 보여줘야 한다.
@Test func fallbacksRoundTripSeparatelyFromUserMapping() throws {
    let store = InMemoryWorkflowStore()
    try store.save(WorkflowMap(statusToStage: ["Done": .done]))
    try store.saveFallbacks(WorkflowMap(statusToStage: ["Merged to Staging": .active]))

    let user = try store.load()
    let fallbacks = try store.loadFallbacks()
    #expect(user?.statusToStage == ["Done": .done])
    #expect(fallbacks?.statusToStage == ["Merged to Staging": .active])
}

@Test func missingFallbackFileLoadsAsNil() throws {
    let loaded = try InMemoryWorkflowStore().loadFallbacks()
    #expect(loaded == nil)
}

/// 파일 저장소도 별도 파일을 쓴다. 같은 파일에 쓰면 한쪽이 다른 쪽을 덮는다.
@Test func fileStoreKeepsFallbacksInASeparateFile() throws {
    try withTempDirectory { dir in
        let store = FileWorkflowStore(directory: dir)
        try store.save(WorkflowMap(statusToStage: ["Done": .done]))
        try store.saveFallbacks(WorkflowMap(statusToStage: ["Merged to Staging": .active]))

        let user = try store.load()
        let fallbacks = try store.loadFallbacks()
        #expect(user?.statusToStage == ["Done": .done])
        #expect(fallbacks?.statusToStage == ["Merged to Staging": .active])
    }
}

/// 계정 전환에서 두 파일을 **둘 다** 지운다. 폴백만 지우면 이전 조직의 사용자 매핑이
/// 남아 마법사가 뜨지 않고, 사용자 매핑만 지우면 추정 폴백이 계속 채점에 병합된다.
@Test func clearRemovesBothTheUserMappingAndTheFallbacks() throws {
    try withTempDirectory { dir in
        let store = FileWorkflowStore(directory: dir)
        try store.save(WorkflowMap(statusToStage: ["Done": .done]))
        try store.saveFallbacks(WorkflowMap(statusToStage: ["Merged to Staging": .active]))

        try store.clear()

        let user = try store.load()
        let fallbacks = try store.loadFallbacks()
        #expect(user == nil)
        #expect(fallbacks == nil)
    }
}

/// 매핑을 한 번도 저장하지 않은 계정에서도 전환이 실패로 보이면 안 된다 —
/// 없는 파일을 지우는 것은 오류가 아니다.
@Test func clearOnAnEmptyDirectoryDoesNotThrow() throws {
    try withTempDirectory { dir in
        try FileWorkflowStore(directory: dir).clear()
    }
}
