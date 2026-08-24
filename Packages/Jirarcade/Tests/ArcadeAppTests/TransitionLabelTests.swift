import Testing
import Foundation
import JiraKit
@testable import ArcadeApp

/// `JiraTransition`은 memberwise init이 없고 `Decodable`로만 만들어진다.
private func transition(name: String, to status: String) throws -> JiraTransition {
    let body = """
    {"transitions":[{"id":"1","name":"\(name)","to":{"name":"\(status)"}}]}
    """
    return try #require(JiraTransition.decodeList(Data(body.utf8)).first)
}

/// 대부분의 전이는 이름과 도착 상태가 같다. 그때 "완료 → 완료"는 목록만 어지럽힌다.
@Test func showsOneNameWhenTheTransitionMatchesItsDestination() throws {
    let same = try transition(name: "진행 중", to: "진행 중")

    #expect(same.menuLabel == "진행 중")
}

/// 실물 워크플로에서 만난 경우다 — "검토 중"이라는 이름의 전이가 "STAG 반영"으로 보낸다.
/// 이름만 보여주면 사용자가 고른 것과 대기 배너에 뜨는 도착 상태가 어긋나 보이고,
/// 고르기 전에 어디로 가는지 알 수 없다.
@Test func showsBothWhenTheDestinationDiffersFromTheTransitionName() throws {
    let diverging = try transition(name: "검토 중", to: "STAG 반영")

    #expect(diverging.menuLabel == "검토 중 → STAG 반영")
}

/// 영문 전이 이름이 한글 상태로 보내는 경우도 같은 규칙을 받는다.
@Test func handlesAMixedScriptTransition() throws {
    let mixed = try transition(name: "Under investigation", to: "모니터링")

    #expect(mixed.menuLabel == "Under investigation → 모니터링")
}
