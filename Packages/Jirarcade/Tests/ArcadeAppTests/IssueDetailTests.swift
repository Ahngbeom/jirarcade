import Testing
import Foundation
@testable import ArcadeApp
@testable import ArcadeCore
import JiraKit

/// `signIn`은 `myself()` 다음에 항상 스프린트 필드 카탈로그(`fields()`)를 한 번 더
/// 조회한다. 워크플로 매핑이 비어 있으면 매핑 후보 조회까지 한 번 더 나가는데, 아래
/// `GatedHTTP` 테스트들은 그 세 번째 호출이 상세 페치와 순서를 두고 경합하지 않도록
/// 워크플로를 미리 채워 넣는다. `IssueEditTests.swift`의 동명 헬퍼는 `private`이라
/// 이 파일에서 보이지 않으므로 사본을 둔다.
private func readySeededWorkflow() -> InMemoryWorkflowStore {
    InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["In Progress": .active]))
}

@MainActor
@Test func openingDetailLoadsSummaryDescriptionAndComments() async throws {
    let detailBody = #"""
    {"key":"DEMO-1","fields":{"summary":"제목","description":{"type":"doc","content":[
      {"type":"paragraph","content":[{"type":"text","text":"본문"}]}]}}}
    """#
    let commentBody = #"""
    {"comments":[{"id":"10","author":{"displayName":"어떤 사람"},
      "created":"2026-08-24T09:00:00.000+0900",
      "body":{"type":"doc","content":[{"type":"paragraph","content":[
        {"type":"text","text":"댓글"}]}]}}]}
    """#
    let model = try makeModel(http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            // 로그인 경로는 /myself 다음에 /field, 그다음 매핑 후보용 검색을 부른다
            // (workflow store가 비어 있으므로 routeAfterAuthentication이 매핑 마법사로
            // 간다). 둘 다 결과를 try?로 받아 실패해도 로그인을 막지 않으므로 본문은
            // 무관하고 응답 슬롯만 채우면 된다.
            .init(status: 200, body: Data("{}".utf8)),
            .init(status: 200, body: Data("{}".utf8)),
            .init(status: 200, body: Data(detailBody.utf8)),
            .init(status: 200, body: Data(commentBody.utf8)),
        ])
    })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")

    await model.openDetail(issueKey: "DEMO-1")

    guard case .loaded(let detail) = model.detailState else {
        Issue.record("상세가 로드되지 않았다: \(model.detailState)")
        return
    }
    #expect(detail.summary == "제목")
    #expect(detail.descriptionText == "본문")
    #expect(detail.comments.count == 1)
    #expect(detail.comments[0].text == "댓글")
}

/// Jira가 준 사유를 화면에 옮기지 않는다. 시트 조회는 동기화의 축약 경로 밖에서
/// 돌기 때문에 이 처리를 공짜로 얻지 못한다.
@MainActor
@Test func aFailedDetailFetchDoesNotQuoteJira() async throws {
    let rejected = #"{"errorMessages":["someone@example.com 님의 요청이 거부되었습니다: 사용자 정의 필드 XYZ 필요"]}"#
    let model = try makeModel(http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data("{}".utf8)),
            .init(status: 200, body: Data("{}".utf8)),
            .init(status: 400, body: Data(rejected.utf8)),
        ])
    })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")

    await model.openDetail(issueKey: "DEMO-1")

    guard case .failed(let message) = model.detailState else {
        Issue.record("실패 상태가 아니다: \(model.detailState)")
        return
    }
    #expect(!message.contains("someone@example.com"))
    #expect(!message.contains("XYZ"))
    #expect(!message.contains("거부되었습니다"))
}

/// 시트를 닫으면 받아온 것을 버린다. 남겨두면 다음에 다른 티켓을 열 때
/// 이전 티켓의 본문이 잠깐 보인다.
@MainActor
@Test func closingDetailForgetsWhatWasLoaded() async throws {
    let detailBody = #"{"key":"DEMO-1","fields":{"summary":"제목","description":null}}"#
    let model = try makeModel(http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data("{}".utf8)),
            .init(status: 200, body: Data("{}".utf8)),
            .init(status: 200, body: Data(detailBody.utf8)),
            .init(status: 200, body: Data(#"{"comments":[]}"#.utf8)),
        ])
    })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    await model.openDetail(issueKey: "DEMO-1")
    guard case .loaded = model.detailState else {
        Issue.record("먼저 로드되어야 한다: \(model.detailState)")
        return
    }

    model.closeDetail()

    #expect(model.detailState == .idle)
}

// MARK: - 요청 정체성: 닫힌/갈아치워진 요청의 늦은 응답은 화면에 닿지 않는다
//
// 최종 전체 브랜치 리뷰 Finding 1. 위 `closingDetailForgetsWhatWasLoaded`는 페치가
// **이미 끝난 뒤에** `closeDetail()`을 부른다 — "시트를 닫았는데 페치가 그 뒤에
// 끝나면?"이라는, 이 태스크가 실제로 지키는 경합은 시험하지 않는다. `GatedHTTP`로
// 응답을 붙잡아 두고 그 사이에 닫거나 다른 티켓을 연 뒤에야 풀어준다.

/// 시트를 닫은 뒤 도착한 응답은 `detailState`를 되살리면 안 된다.
@MainActor
@Test func closingTheSheetMidFetchDiscardsTheLateResponse() async throws {
    let gate = GatedHTTP(leading: [
        .init(status: 200, body: Data(myselfBody.utf8)),   // /myself
        .init(status: 200, body: Data("[]".utf8)),         // signIn의 field
    ])
    let model = try makeModel(workflow: readySeededWorkflow(), http: { gate })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")

    let detailBody = #"{"key":"DEMO-1","fields":{"summary":"제목","description":null}}"#
    let openTask = Task { await model.openDetail(issueKey: "DEMO-1") }
    await gate.waitUntilEntered()

    model.closeDetail()
    #expect(model.detailState == .idle)

    // 시트를 닫은 뒤에야 상세 응답이 도착한다.
    await gate.release(status: 200, body: Data(detailBody.utf8))
    await openTask.value

    #expect(model.detailState == .idle)
    // 상세 응답만 나갔다 — 닫은 뒤 이어지는 댓글 요청은 나가지 않는다(myself + field
    // + 상세 = 3). 나갔다면 로그아웃/닫힘 뒤에도 Jira에 계속 말을 거는 것이다.
    #expect(await gate.requestCount == 3)
}

/// A를 닫고 B를 연 뒤 B가 먼저 다 끝나고 나서야 A의 응답이 도착해도, 화면은 계속
/// B의 것이어야 한다. `syncGeneration`은 계정이 그대로라 이 경합을 잡지 못한다 —
/// 요청 토큰만이 잡는다.
@MainActor
@Test func openingADifferentTicketAfterClosingKeepsTheNewTicketsState() async throws {
    let gate = GatedHTTP(leading: [
        .init(status: 200, body: Data(myselfBody.utf8)),   // /myself
        .init(status: 200, body: Data("[]".utf8)),         // signIn의 field
    ])
    let model = try makeModel(workflow: readySeededWorkflow(), http: { gate })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")

    let detailBodyA = #"{"key":"DEMO-1","fields":{"summary":"A의 제목","description":null}}"#
    let openTaskA = Task { await model.openDetail(issueKey: "DEMO-1") }
    await gate.waitUntilEntered()   // DEMO-1의 상세 요청이 게이트에 걸려 멈춰 있다.

    model.closeDetail()

    // DEMO-2는 게이트와 무관하게 즉시 끝난다 — `leading`에 미리 채워 넣은 응답을
    // 곧바로 소비하므로, 아직 풀리지 않은 DEMO-1의 게이트와 부딪히지 않는다.
    let detailBodyB = #"{"key":"DEMO-2","fields":{"summary":"B의 제목","description":null}}"#
    await gate.enqueueLeading([
        .init(status: 200, body: Data(detailBodyB.utf8)),
        .init(status: 200, body: Data(#"{"comments":[]}"#.utf8)),
    ])
    await model.openDetail(issueKey: "DEMO-2")

    guard case .loaded(let loadedB) = model.detailState, loadedB.key == "DEMO-2" else {
        Issue.record("DEMO-2가 먼저 로드되어 있어야 한다: \(model.detailState)")
        return
    }

    // 이제야 DEMO-1의 상세 응답이 도착한다.
    await gate.release(status: 200, body: Data(detailBodyA.utf8))
    await openTaskA.value

    guard case .loaded(let loaded) = model.detailState else {
        Issue.record("DEMO-2가 그대로 로드된 상태여야 한다: \(model.detailState)")
        return
    }
    #expect(loaded.key == "DEMO-2")
    #expect(loaded.summary == "B의 제목")
    // DEMO-1의 댓글 요청은 끝내 나가지 않는다 — myself + field + DEMO-1 상세
    // + DEMO-2 상세 + DEMO-2 댓글 = 5.
    #expect(await gate.requestCount == 5)
}
