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
@Test func postingACommentSucceeds() async throws {
    let model = try makeModel(
        workflow: readySeededWorkflow(),
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),   // /myself
                .init(status: 200, body: Data("[]".utf8)),         // signIn의 field
                .init(status: 201, body: Data("{}".utf8)),         // POST comment
                .init(status: 200, body: Data(#"{"issues":[],"isLast":true}"#.utf8)), // 뒤따르는 동기화
            ])
        }
    )
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    let posted = await model.postComment(issueKey: "DEMO-1", text: "확인했습니다")

    #expect(posted)
    #expect(model.editInFlight.isEmpty)
    #expect(model.editFailures["DEMO-1"] == nil)
}

/// 빈 댓글은 보내지 않는다. 공백만 친 뒤 저장을 누른 것은 등록 의사가 아니다.
@MainActor
@Test func whitespaceOnlyCommentIsNotSent() async throws {
    let http = ScriptedHTTP([.init(status: 200, body: Data(myselfBody.utf8))])
    let model = try makeModel(http: { http })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    let posted = await model.postComment(issueKey: "DEMO-1", text: "   \n  ")

    // 큐가 비었으므로 요청이 하나라도 더 나갔다면 URLError로 실패했을 것이다.
    #expect(!posted)
    #expect(model.editFailures["DEMO-1"] == nil)
    #expect(model.editInFlight.isEmpty)
}

/// 400 같은 보통 실패는 `editFailures`에 사유를 남기고, 반환값으로도 실패를 알린다 —
/// 시트가 이 값으로 초안을 지울지 정한다.
@MainActor
@Test func aRejectedCommentReportsFailure() async throws {
    let model = try makeModel(
        workflow: readySeededWorkflow(),
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),   // /myself
                .init(status: 200, body: Data("[]".utf8)),         // signIn의 field
                .init(status: 400, body: Data("{}".utf8)),         // POST comment rejected
            ])
        }
    )
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    let posted = await model.postComment(issueKey: "DEMO-1", text: "확인했습니다")

    #expect(!posted)
    #expect(model.editFailures["DEMO-1"] != nil)
    #expect(model.editInFlight.isEmpty)
}

/// 401은 `editFailures`를 일부러 비워 둔다(만료 배너와 중복 방지) — 그 부재가
/// 성공과 구분되지 않으므로, 시트는 반환값만으로 성공 여부를 판단해야 한다.
/// 이 반환값이 없으면 401도 성공처럼 보여 초안이 날아가고 시트가 같은 401로
/// 다시 멈춘다.
@MainActor
@Test func anExpiredTokenDuringACommentReportsFailureWithoutAFieldFailure() async throws {
    let model = try makeModel(
        workflow: readySeededWorkflow(),
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),   // /myself
                .init(status: 200, body: Data("[]".utf8)),         // signIn의 field
                .init(status: 401, body: Data("{}".utf8)),         // POST comment unauthorized
            ])
        }
    )
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    let posted = await model.postComment(issueKey: "DEMO-1", text: "확인했습니다")

    #expect(!posted)
    #expect(model.phase == .expired)
    #expect(model.editFailures["DEMO-1"] == nil)
    #expect(model.editInFlight.isEmpty)
}

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

// MARK: - 로그아웃과 실제로 날아가는 중인 저장의 경합
//
// 위 테스트들은 `ScriptedHTTP`가 즉시 응답하기 때문에 `saveSummary`가 이미 끝난
// **뒤에** `signOut()`을 부른다 — 이 태스크가 존재하는 이유인 "저장이 실제로 대기
// 중일 때 로그아웃이 오면?"이라는 경합은 하나도 만들지 않는다. `GatedHTTP`로 PUT
// 응답을 붙잡아 두고 그 사이에 로그아웃을 흘려보낸 뒤에야 풀어준다 — 세 가지 결과
// (성공/거부/만료)로 각각 풀어서 `saveSummary`의 세 `generation == self.syncGeneration`
// 검사를 하나씩 겨냥한다.

/// 성공 분기의 세대 검사(`guard generation == self.syncGeneration else { return }`)는
/// 로그아웃만으로는 실제로 시험되지 않는다 — 로그아웃이 `client`를 `nil`로 만들어
/// 버리므로, 그 검사를 지워도 뒤이은 `syncNow()`는 `performSync()`의
/// `guard let client`에서 막힌다(별개의, 이미 있던 방어선). 이 검사가 실제로 막아야
/// 하는 사고는 사고 보고서 그대로다 — 로그아웃 **뒤에 다른 계정으로 재로그인**해
/// `client`가 다시 채워진 상태에서 옛 저장이 뒤늦게 성공으로 돌아오는 경우다. 그래서
/// `signOut()` 다음에 두 번째 `signIn()`을 끼워 넣는다.
@MainActor
@Test func lateSuccessAfterSignOutAndReSignInDoesNotSyncTheNewAccount() async throws {
    let gate = GatedHTTP(leading: [
        .init(status: 200, body: Data(myselfBody.utf8)),   // 첫 계정 /myself
        .init(status: 200, body: Data("[]".utf8)),         // 첫 계정 signIn의 field
    ])
    let model = try makeModel(workflow: readySeededWorkflow(), http: { gate })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    let saveTask = Task { await model.saveSummary(issueKey: "DEMO-1", summary: "새 제목") }
    await gate.waitUntilEntered()
    #expect(model.editInFlight.contains("DEMO-1"))

    await model.signOut()
    // 다른 계정으로 재로그인한다 — `client`가 다시 채워지고 `syncGeneration`이 한 번
    // 더 오른다. 옛 저장의 `generation`은 이제 두 세대나 뒤처졌다.
    await gate.enqueueLeading([
        .init(status: 200, body: Data(myselfBody.utf8)),   // 둘째 계정 /myself
        .init(status: 200, body: Data("[]".utf8)),         // 둘째 계정 signIn의 field
    ])
    await model.signIn(site: "example.atlassian.net", email: "b@example.com", token: "t2")

    // 첫 계정의 PUT이 이제야 성공으로 돌아온다 — 재로그인 전에 이미 날아간
    // 요청이므로 막을 수 없다. 하지만 그 결과가 둘째 계정의 화면에 쓰이거나
    // 둘째 계정의 `client`로 동기화를 일으켜서는 안 된다.
    await gate.release(status: 204, body: Data())
    await saveTask.value

    #expect(model.editFailures.isEmpty)
    #expect(model.editInFlight.isEmpty)
    #expect(model.editTaskCountForTesting == 0)
    #expect(model.phase != .expired)
    // myself + field(첫 계정) + PUT + myself + field(둘째 계정) = 5. 세대 검사가
    // 없다면 `syncNow`가 둘째 계정의 `client`로 실제 검색 요청(6번째)을 내보낸다 —
    // `GatedHTTP`는 게이트를 지난 뒤의 호출을 매달아 두지 않고 즉시 에러로
    // 되돌리므로(정확히 한 번만 멈추는 스텁), 테스트가 멈추지 않고 이 카운트로
    // 곧바로 드러난다.
    #expect(await gate.requestCount == 5)
}

@MainActor
@Test func lateRejectionAfterSignOutDoesNotSurfaceAFailure() async throws {
    let gate = GatedHTTP(leading: [
        .init(status: 200, body: Data(myselfBody.utf8)),
        .init(status: 200, body: Data("[]".utf8)),
    ])
    let model = try makeModel(workflow: readySeededWorkflow(), http: { gate })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    let saveTask = Task { await model.saveSummary(issueKey: "DEMO-1", summary: "새 제목") }
    await gate.waitUntilEntered()

    await model.signOut()
    // 400이 이제야 도착한다. 일반 실패 분기의 세대 검사가 없으면 이미 로그아웃해
    // 빈 화면인 이 모델에 남의 실패 문구가 쓰인다.
    await gate.release(status: 400, body: Data("{}".utf8))
    await saveTask.value

    #expect(model.editFailures.isEmpty)
    #expect(model.editInFlight.isEmpty)
    #expect(model.editTaskCountForTesting == 0)
    #expect(model.detailState == .idle)
}

@MainActor
@Test func lateUnauthorizedAfterSignOutDoesNotExpireTheNewSession() async throws {
    let gate = GatedHTTP(leading: [
        .init(status: 200, body: Data(myselfBody.utf8)),
        .init(status: 200, body: Data("[]".utf8)),
    ])
    let model = try makeModel(workflow: readySeededWorkflow(), http: { gate })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    let saveTask = Task { await model.saveSummary(issueKey: "DEMO-1", summary: "새 제목") }
    await gate.waitUntilEntered()

    await model.signOut()
    // 401이 이제야 도착한다. 만료 분기의 세대 검사가 없으면 이미 로그아웃해
    // `.signedOut`으로 넘어간 phase가 `.expired`로 다시 덧씌워진다 — 사용자는 방금
    // 로그아웃했는데 세션이 만료됐다는 배너를 본다.
    await gate.release(status: 401, body: Data("{}".utf8))
    await saveTask.value

    #expect(model.phase != .expired)
    #expect(model.editFailures.isEmpty)
    #expect(model.editInFlight.isEmpty)
    #expect(model.editTaskCountForTesting == 0)
}

/// `postComment`도 `saveSummary`와 같은 성공 분기 세대 검사를 쓴다. 단순
/// 로그아웃만으로는 시험되지 않는다 — `client`가 `nil`이 되어 뒤이은 `syncNow()`가
/// 그 자체의 `guard let client`에서 막혀 버리기 때문이다(별개의, 이미 있던 방어선).
/// 그 검사가 실제로 막아야 하는 사고는 로그아웃 **뒤에 다른 계정으로 재로그인**해
/// `client`가 다시 채워진 상태에서 옛 댓글 등록이 뒤늦게 성공으로 돌아오는 경우다.
@MainActor
@Test func lateCommentSuccessAfterSignOutAndReSignInDoesNotSyncTheNewAccount() async throws {
    let gate = GatedHTTP(leading: [
        .init(status: 200, body: Data(myselfBody.utf8)),   // 첫 계정 /myself
        .init(status: 200, body: Data("[]".utf8)),         // 첫 계정 signIn의 field
    ])
    let model = try makeModel(workflow: readySeededWorkflow(), http: { gate })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    let postTask = Task { await model.postComment(issueKey: "DEMO-1", text: "확인했습니다") }
    await gate.waitUntilEntered()
    #expect(model.editInFlight.contains("DEMO-1"))

    await model.signOut()
    // 다른 계정으로 재로그인한다 — `client`가 다시 채워지고 `syncGeneration`이 한 번
    // 더 오른다. 옛 댓글 등록의 `generation`은 이제 두 세대나 뒤처졌다.
    await gate.enqueueLeading([
        .init(status: 200, body: Data(myselfBody.utf8)),   // 둘째 계정 /myself
        .init(status: 200, body: Data("[]".utf8)),         // 둘째 계정 signIn의 field
    ])
    await model.signIn(site: "example.atlassian.net", email: "b@example.com", token: "t2")

    // 첫 계정의 POST가 이제야 성공으로 돌아온다 — 재로그인 전에 이미 날아간
    // 요청이므로 막을 수 없다. 하지만 그 결과가 둘째 계정의 화면에 쓰이거나
    // 둘째 계정의 `client`로 동기화를 일으켜서는 안 된다.
    await gate.release(status: 201, body: Data("{}".utf8))
    await postTask.value

    #expect(model.editFailures.isEmpty)
    #expect(model.editInFlight.isEmpty)
    #expect(model.editTaskCountForTesting == 0)
    #expect(model.phase != .expired)
    // myself + field(첫 계정) + POST + myself + field(둘째 계정) = 5. 세대 검사가
    // 없다면 `syncNow`가 둘째 계정의 `client`로 실제 검색 요청(6번째)을 내보낸다.
    #expect(await gate.requestCount == 5)
}
