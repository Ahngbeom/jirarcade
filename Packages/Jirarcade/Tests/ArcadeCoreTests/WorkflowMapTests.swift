import Testing
import Foundation
@testable import ArcadeCore

@Test func demoMappingCoversConfiguredStatuses() {
    let map = demoWorkflow
    #expect(map.stage(for: "To Do") == .backlog)
    #expect(map.stage(for: "In Progress") == .active)
    #expect(map.stage(for: "In Review") == .review)
    #expect(map.stage(for: "Verifying") == .verify)
    #expect(map.stage(for: "Done") == .done)
}

@Test func unknownStatusReturnsNilRatherThanFallback() {
    #expect(demoWorkflow.stage(for: "검토 대기") == nil)
}

@Test func unmappedStatusesAreReported() {
    let found = demoWorkflow.unmappedStatuses(in: ["In Progress", "검토 대기", "보류", "In Progress"])
    #expect(found == ["검토 대기", "보류"])
}

@Test func stageOrderIsMonotonic() {
    let ordered: [Stage] = [.backlog, .active, .review, .verify, .done]
    let orders = ordered.map(\.order)
    #expect(orders == [0, 1, 2, 3, 4])
}

// MARK: - 제외 목록

/// 제외한 상태는 폴백 추정에서도 걷힌다.
///
/// 이 구분이 없으면 마법사에서 상태를 되돌려도 추정값이 **밑에 깔린 채** 계속 채점된다 —
/// 잘못 추정된 상태를 다른 단계로 바꾸는 것만 되고 끄는 것은 안 된다. 실물에서 보류 성격의
/// 상태가 statusCategory가 done이라 완료로 채점되고 마감 보너스까지 받은 사례가 여기서 온다.
@Test func excludedStatusIsNotScoredEvenWhenAFallbackExists() {
    let map = WorkflowMap(statusToStage: ["In Progress": .active],
                          excludedStatuses: ["On Hold"])
    let effective = map.merging(["On Hold": .done, "QA Passed": .verify])

    #expect(effective.stage(for: "On Hold") == nil, "제외한 상태는 추정도 적용되지 않는다")
    #expect(effective.stage(for: "QA Passed") == .verify, "제외하지 않은 폴백은 그대로다")
    #expect(effective.stage(for: "In Progress") == .active)
}

/// 명시적으로 매핑한 상태는 제외 목록에 있어도 그대로 채점된다.
///
/// 둘은 모순이라 마법사가 동시에 고르지 못하게 하지만, 손으로 고친 `workflow.json`이
/// 들어와도 실효 맵이 조용히 무동작이 되면 안 된다 — 사용자가 적어둔 단계가 이긴다.
@Test func anExplicitMappingSurvivesAContradictoryExclusion() {
    let map = WorkflowMap(statusToStage: ["On Hold": .review], excludedStatuses: ["On Hold"])
    #expect(map.merging(["On Hold": .done]).stage(for: "On Hold") == .review)
}

/// 실효 맵도 제외 목록을 그대로 들고 간다. 잃어버리면 그 맵으로 한 번 더 병합할 때
/// 제외가 조용히 풀린다.
@Test func mergingCarriesExclusionsForward() {
    let map = WorkflowMap(statusToStage: [:], excludedStatuses: ["On Hold"])
    #expect(map.merging(["Done": .done]).excludedStatuses == ["On Hold"])
}

/// 제외한 상태는 "매핑되지 않은 상태" 경고에서 빠진다 — 사용자가 스스로 끈 것이라
/// 남겨두면 끄는 순간 지울 방법이 없는 경고가 화면에 붙는다.
@Test func excludedStatusesAreNotReportedAsUnmapped() {
    let map = WorkflowMap(statusToStage: ["In Progress": .active],
                          excludedStatuses: ["On Hold"])
    #expect(map.unmappedStatuses(in: ["In Progress", "On Hold", "검토 대기"]) == ["검토 대기"])
}

/// 제외 목록이 생기기 전에 저장된 `workflow.json`을 그대로 읽어야 한다.
/// 자동 합성 `Codable`은 누락 키에 기본값을 쓰지 않으므로, 직접 디코딩하지 않으면
/// 기존 사용자의 매핑이 통째로 읽히지 않아 마법사가 처음부터 다시 뜬다.
@Test func mappingSavedBeforeExclusionsExistedStillDecodes() throws {
    let legacy = #"{"statusToStage":{"In Progress":"active","Done":"done"}}"#
    let map = try JSONDecoder().decode(WorkflowMap.self, from: Data(legacy.utf8))

    #expect(map.statusToStage == ["In Progress": .active, "Done": .done])
    #expect(map.excludedStatuses.isEmpty, "없던 키는 '제외 없음'으로 읽힌다")
}

@Test func exclusionsSurviveAnEncodeDecodeRoundTrip() throws {
    let map = WorkflowMap(statusToStage: ["Done": .done], excludedStatuses: ["On Hold"])
    let data = try JSONEncoder().encode(map)
    #expect(try JSONDecoder().decode(WorkflowMap.self, from: data) == map)
}
