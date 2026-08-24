import Testing
import Foundation
@testable import ArcadeApp

@Test func remembersTheFieldIDAcrossLoads() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileSprintFieldStore(directory: directory)

    try store.save("customfield_10020")

    #expect(try FileSprintFieldStore(directory: directory).load() == "customfield_10020")
}

@Test func reportsNothingBeforeAnythingIsSaved() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(try FileSprintFieldStore(directory: directory).load() == nil)
}

/// 계정이 바뀌면 버린다 — 다른 테넌트의 필드 ID는 무의미하고, 남겨두면 그 사이트에
/// 존재하지 않는 필드를 계속 요청하게 된다.
@Test func forgetsTheFieldIDWhenCleared() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileSprintFieldStore(directory: directory)
    try store.save("customfield_10020")

    try store.clear()

    #expect(try store.load() == nil)
}

/// 저장한 적 없는 상태에서 지워도 오류가 아니다 — 로그아웃 경로가 항상 부르기 때문이다.
@Test func clearingWhenEmptyIsNotAnError() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileSprintFieldStore(directory: directory).clear()
}
