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

/// 최종 전체 브랜치 리뷰 Finding 1. `validate()`는 계정 전환을 감지하면 스토어·워크플로와
/// 함께 스프린트 필드 ID도 버려야 한다 — 그러지 않으면 A 사이트의 `customfield_*`가 그
/// 필드조차 없는 B 사이트로 계속 전송돼 검색 요청 전체가 거부될 수 있다.
@MainActor
@Test func accountSwitchDiscardsThePreviousSitesFieldID() async throws {
    let sprintField = InMemorySprintFieldStore()
    // clientFactory가 signIn()마다 다시 불리므로, 계정별로 서로 다른 응답을 주려면
    // 호출마다 새 ScriptedHTTP를 꺼내야 한다(`signOutThenDifferentAccountClearsTheMirrorAndEventLog`와
    // 같은 패턴).
    var scripts: [ScriptedHTTP] = [
        ScriptedHTTP([
            .init(status: 200, body: Data(#"{"accountId":"acc-first","displayName":"First"}"#.utf8)),
            .init(status: 200, body: Data(fieldsBody.utf8)),
        ]),
        ScriptedHTTP([
            .init(status: 200, body: Data(#"{"accountId":"acc-second","displayName":"Second"}"#.utf8)),
            .init(status: 200, body: Data("""
            [{"id":"summary","name":"Summary","schema":{"type":"string"}}]
            """.utf8)),
        ]),
    ]
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: activeOnlyWorkflow),
        sprintField: sprintField,
        http: { scripts.removeFirst() }
    )

    await model.signIn(site: "example.atlassian.net", email: "first@e.com", token: "t1")
    #expect(try sprintField.load() == "customfield_10020")

    await model.signIn(site: "example.atlassian.net", email: "second@e.com", token: "t2")

    #expect(try sprintField.load() == nil,
            "계정 전환 뒤에도 첫 사이트의 필드 ID가 남아 있다")
}

/// 위 테스트가 놓치는 함정을 잡는다: 전환 검사의 `sprintField.clear()`가 **무조건** 실행되면,
/// 새 사이트가 실제로 스프린트 필드를 갖고 있어도 방금 저장한 값을 도로 지워버린다.
/// `validate()`가 전환 검사 → 조회·기록 순서를 지켜야만 이 테스트가 통과한다.
@MainActor
@Test func accountSwitchToASiteWithItsOwnSprintFieldKeepsTheNewID() async throws {
    let sprintField = InMemorySprintFieldStore()
    var scripts: [ScriptedHTTP] = [
        ScriptedHTTP([
            .init(status: 200, body: Data(#"{"accountId":"acc-first","displayName":"First"}"#.utf8)),
            .init(status: 200, body: Data(fieldsBody.utf8)),
        ]),
        ScriptedHTTP([
            .init(status: 200, body: Data(#"{"accountId":"acc-second","displayName":"Second"}"#.utf8)),
            .init(status: 200, body: Data("""
            [{"id":"customfield_10099","name":"Sprint",
              "schema":{"type":"array","custom":"com.pyxis.greenhopper.jira:gh-sprint"}}]
            """.utf8)),
        ]),
    ]
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: activeOnlyWorkflow),
        sprintField: sprintField,
        http: { scripts.removeFirst() }
    )

    await model.signIn(site: "example.atlassian.net", email: "first@e.com", token: "t1")
    #expect(try sprintField.load() == "customfield_10020")

    await model.signIn(site: "example.atlassian.net", email: "second@e.com", token: "t2")

    #expect(try sprintField.load() == "customfield_10099",
            "전환 검사가 방금 찾은 새 사이트의 유효한 ID까지 지우면 안 된다")
}

/// 최종 전체 브랜치 리뷰 Finding 1의 authoritative-lookup 절반: 계정 전환 없이도, 사이트가
/// 스프린트 필드를 잃으면(관리자가 지웠거나 프로젝트 구성을 바꾼 경우) 다음 로그인에서
/// 저장된 ID를 지워야 한다 — 남겨두면 이미 없는 필드를 계속 요청하게 된다.
@MainActor
@Test func aSiteThatLosesItsSprintFieldClearsTheStoredID() async throws {
    let sprintField = InMemorySprintFieldStore()
    var scripts: [ScriptedHTTP] = [
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data(fieldsBody.utf8)),
        ]),
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data("""
            [{"id":"summary","name":"Summary","schema":{"type":"string"}}]
            """.utf8)),
        ]),
    ]
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: activeOnlyWorkflow),
        sprintField: sprintField,
        http: { scripts.removeFirst() }
    )

    await model.signIn(site: "example.atlassian.net", email: "u@e.com", token: "t1")
    #expect(try sprintField.load() == "customfield_10020")

    await model.signIn(site: "example.atlassian.net", email: "u@e.com", token: "t2")

    #expect(try sprintField.load() == nil,
            "필드가 사라진 뒤에도 옛 ID가 남으면 검색이 400으로 거부될 수 있다")
}

/// authoritative-lookup의 반대쪽 경계: `/field` 조회 자체가 실패한 것은 "필드가 없다"는
/// 사실이 아니다. 여기서 지우면 네트워크가 잠깐 흔들릴 때마다 멀쩡한 사이트의 이월 표시가
/// 꺼진다.
@MainActor
@Test func aFailedFieldLookupDoesNotWipeAValidStoredID() async throws {
    let sprintField = InMemorySprintFieldStore()
    var scripts: [ScriptedHTTP] = [
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data(fieldsBody.utf8)),
        ]),
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 500, body: Data()),
        ]),
    ]
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: activeOnlyWorkflow),
        sprintField: sprintField,
        http: { scripts.removeFirst() }
    )

    await model.signIn(site: "example.atlassian.net", email: "u@e.com", token: "t1")
    #expect(try sprintField.load() == "customfield_10020")

    await model.signIn(site: "example.atlassian.net", email: "u@e.com", token: "t2")

    #expect(try sprintField.load() == "customfield_10020",
            "조회 자체가 실패했을 뿐 필드가 없어졌다는 뜻은 아니다")
}
