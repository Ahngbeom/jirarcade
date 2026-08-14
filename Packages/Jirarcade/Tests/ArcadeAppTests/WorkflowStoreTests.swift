import Testing
import Foundation
import ArcadeCore
@testable import ArcadeApp

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("jirarcade-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func savedMappingComesBack() throws {
    let store = FileWorkflowStore(directory: tempDirectory())
    let map = WorkflowMap(statusToStage: ["To Do": .backlog, "Done": .done])
    try store.save(map)
    #expect(try store.load() == map)
}

@Test func missingFileReturnsNil() throws {
    #expect(try FileWorkflowStore(directory: tempDirectory()).load() == nil)
}

@Test func savingTwiceReplaces() throws {
    let store = FileWorkflowStore(directory: tempDirectory())
    try store.save(WorkflowMap(statusToStage: ["To Do": .backlog]))
    try store.save(WorkflowMap(statusToStage: ["Done": .done]))
    #expect(try store.load()?.statusToStage.count == 1)
    #expect(try store.load()?.stage(for: "Done") == .done)
}

@Test func corruptedFileThrowsRatherThanReturningEmpty() throws {
    let dir = tempDirectory()
    let store = FileWorkflowStore(directory: dir)
    try Data("not json".utf8).write(to: dir.appendingPathComponent("workflow.json"))
    #expect(throws: (any Error).self) { try store.load() }
}

@Test func nonAsciiStatusNamesSurvive() throws {
    let store = FileWorkflowStore(directory: tempDirectory())
    let map = WorkflowMap(statusToStage: ["진행 중": .active, "완료": .done])
    try store.save(map)
    #expect(try store.load() == map)
}
