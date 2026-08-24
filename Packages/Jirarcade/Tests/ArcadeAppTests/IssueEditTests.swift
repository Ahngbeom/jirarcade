import Testing
import Foundation
@testable import ArcadeApp
@testable import ArcadeCore
import JiraKit

/// `signIn`은 `myself()` 다음에 항상 스프린트 필드 카탈로그(`fields()`)를 한 번 더
/// 조회한다(`AppModel.validate` 참고). 워크플로 매핑이 비어 있으면 그 뒤에 매핑 후보
/// 조회(`mappingCandidates()`)까지 한 번 더 나간다 — 이 파일의 테스트는 그 세 번째
/// 호출이 저장 요청과 스크립트 순서를 두고 경합하지 않도록 워크플로를 미리 채워 넣는다.
/// `TransitionTests.swift`의 동명 헬퍼는 `private`이라 이 파일에서 보이지 않으므로 사본을 둔다.
private func readySeededWorkflow() -> InMemoryWorkflowStore {
    InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["In Progress": .active]))
}

@MainActor
@Test func savingSummarySucceedsAndClearsInFlight() async throws {
    let model = try makeModel(
        workflow: readySeededWorkflow(),
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),   // /myself
                .init(status: 200, body: Data("[]".utf8)),         // signIn의 field
                .init(status: 204, body: Data()),                  // PUT summary
                .init(status: 200, body: Data(#"{"issues":[],"isLast":true}"#.utf8)), // 뒤따르는 동기화
            ])
        }
    )
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    await model.saveSummary(issueKey: "DEMO-1", summary: "새 제목")

    #expect(model.editInFlight.isEmpty)
    #expect(model.editFailures["DEMO-1"] == nil)
}

/// 400이 담아 오는 것은 Jira 응답 본문이고 거기에는 이메일이 섞일 수 있다.
@MainActor
@Test func aRejectedSaveDoesNotQuoteJira() async throws {
    let rejected = #"{"errorMessages":["someone@example.com: summary is too long"]}"#
    let model = try makeModel(
        workflow: readySeededWorkflow(),
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),   // /myself
                .init(status: 200, body: Data("[]".utf8)),         // signIn의 field
                .init(status: 400, body: Data(rejected.utf8)),     // PUT summary rejected
            ])
        }
    )
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    await model.saveSummary(issueKey: "DEMO-1", summary: "새 제목")

    let message = try #require(model.editFailures["DEMO-1"])
    #expect(!message.contains("someone@example.com"))
    #expect(!message.contains("too long"))
}

@MainActor
@Test func dismissingTheFailureUnlocksTheField() async throws {
    let model = try makeModel(
        workflow: readySeededWorkflow(),
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),   // /myself
                .init(status: 200, body: Data("[]".utf8)),         // signIn의 field
                .init(status: 400, body: Data("{}".utf8)),         // PUT summary rejected
            ])
        }
    )
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])
    await model.saveSummary(issueKey: "DEMO-1", summary: "새 제목")
    #expect(model.editFailures["DEMO-1"] != nil)

    model.dismissEditFailure(issueKey: "DEMO-1")

    #expect(model.editFailures["DEMO-1"] == nil)
}

/// 로그아웃은 "Jira와 더 이상 말하지 않는다"이다. 진행 중인 저장을 남겨두면
/// 다음 계정의 client로 옛 티켓 키에 쓸 수 있다.
@MainActor
@Test func signOutClearsEditStateAndTasks() async throws {
    let model = try makeModel(
        workflow: readySeededWorkflow(),
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),   // /myself
                .init(status: 200, body: Data("[]".utf8)),         // signIn의 field
                .init(status: 400, body: Data("{}".utf8)),         // PUT summary rejected
            ])
        }
    )
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])
    await model.saveSummary(issueKey: "DEMO-1", summary: "새 제목")
    #expect(model.editFailures["DEMO-1"] != nil)

    await model.signOut()

    #expect(model.editFailures.isEmpty)
    #expect(model.editInFlight.isEmpty)
    #expect(model.editTaskCountForTesting == 0)
    #expect(model.detailState == .idle)
}

/// 401은 만료 배너가 이미 같은 사실을 말한다. 시트에도 실패를 띄우면 인증 문제가
/// 두 번 보이고 사용자는 티켓 문제와 세션 문제를 구분하지 못한다.
@MainActor
@Test func anExpiredTokenMovesToExpiredWithoutAFieldFailure() async throws {
    let model = try makeModel(
        workflow: readySeededWorkflow(),
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),   // /myself
                .init(status: 200, body: Data("[]".utf8)),         // signIn의 field
                .init(status: 401, body: Data("{}".utf8)),         // PUT summary unauthorized
            ])
        }
    )
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    await model.saveSummary(issueKey: "DEMO-1", summary: "새 제목")

    #expect(model.phase == .expired)
    #expect(model.editFailures["DEMO-1"] == nil)
}
