import Testing
@testable import ArcadeApp

@Test func expiredStillShowsTheMirror() {
    #expect(Phase.expired.showsMirror == true, "인증 실패는 읽기 불가가 아니다")
    #expect(Phase.expired.allowsWriting == false)
}

@Test func signedOutHidesTheMirror() {
    #expect(Phase.signedOut(message: nil).showsMirror == false)
    #expect(Phase.signedOut(message: nil).allowsWriting == false)
}

@Test func readyAllowsEverything() {
    #expect(Phase.ready.showsMirror == true)
    #expect(Phase.ready.allowsWriting == true)
}

@Test(arguments: [
    Phase.launching, .validating, .mappingWorkflow(candidates: ["To Do"]),
])
func transientPhasesShowNothingAndWriteNothing(phase: Phase) {
    #expect(phase.showsMirror == false, "온보딩 중에는 캐비닛이 보이지 않는다")
    #expect(phase.allowsWriting == false)
}

@Test func phasesWithPayloadsCompareByPayload() {
    #expect(Phase.signedOut(message: "a") != Phase.signedOut(message: "b"))
    #expect(Phase.mappingWorkflow(candidates: ["A"]) != .mappingWorkflow(candidates: ["B"]))
}
