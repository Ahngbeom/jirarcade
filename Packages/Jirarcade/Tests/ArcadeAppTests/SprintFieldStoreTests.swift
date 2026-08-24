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

import ArcadeCore
import JiraKit

private let fieldsBody = """
[{"id":"customfield_10020","name":"스프린트",
  "schema":{"type":"array","custom":"com.pyxis.greenhopper.jira:gh-sprint"}}]
"""

/// `demoWorkflow`는 `ArcadeCoreTests`의 파일 스코프 픽스처라 이 타깃에서 보이지 않는다.
/// 이 테스트들이 매핑에서 필요한 것은 "마법사로 라우팅되지 않는다"뿐이므로 최소 맵을 쓴다 —
/// 매핑이 비어 있으면 `routeAfterAuthentication()`이 마법사로 보내고, 마법사가 HTTP 응답을
/// 하나 더 소비해 `ScriptedHTTP`의 순서가 어긋난다.
private let activeOnlyWorkflow = WorkflowMap(statusToStage: ["In Progress": .active])

/// 로그인하면 필드 목록을 한 번 조회해 스프린트 필드 ID를 저장한다.
@MainActor
@Test func findsAndStoresTheSprintFieldOnSignIn() async throws {
    let sprintField = InMemorySprintFieldStore()
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: activeOnlyWorkflow),
        sprintField: sprintField,
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 200, body: Data(fieldsBody.utf8)),
            ])
        }
    )

    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")

    #expect(try sprintField.load() == "customfield_10020")
}

/// 스프린트를 쓰지 않는 사이트에서도 로그인이 정상으로 끝나야 한다.
/// 필드가 없다는 것은 오류가 아니라 사실이다.
@MainActor
@Test func signsInNormallyWhenTheSiteHasNoSprintField() async throws {
    let sprintField = InMemorySprintFieldStore()
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: activeOnlyWorkflow),
        sprintField: sprintField,
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 200, body: Data("""
                [{"id":"summary","name":"Summary","schema":{"type":"string"}}]
                """.utf8)),
            ])
        }
    )

    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")

    #expect(try sprintField.load() == nil)
    // 로그인이 끝났다는 것은 계정을 알아냈다는 뜻이다. `Phase` 비교보다 이쪽이
    // 연관값에 흔들리지 않는다.
    #expect(model.myAccountId != nil)
}

/// `/field` 조회가 실패해도 로그인을 막지 않는다 — 이월 표시만 없는 채로 돈다.
@MainActor
@Test func survivesAFailedFieldLookup() async throws {
    let sprintField = InMemorySprintFieldStore()
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: activeOnlyWorkflow),
        sprintField: sprintField,
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 500, body: Data()),
            ])
        }
    )

    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")

    #expect(try sprintField.load() == nil)
}

/// 계정이 바뀌면 필드 ID를 버린다 — 다른 테넌트에 그 필드는 없다.
@MainActor
@Test func forgetsTheFieldIDOnSignOut() async throws {
    let sprintField = InMemorySprintFieldStore(seeded: "customfield_10020")
    let model = try makeModel(sprintField: sprintField)

    await model.signOut()

    #expect(try sprintField.load() == nil)
}
