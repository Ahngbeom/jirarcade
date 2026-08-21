import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

/// 사용자가 마법사에서 지정한 매핑이 폴백 추정값을 이긴다.
@Test func userMappingBeatsFallback() {
    let user = WorkflowMap(statusToStage: ["Merged to Staging": .review])
    let effective = user.merging(["Merged to Staging": .active, "QA Passed": .verify])

    #expect(effective.stage(for: "Merged to Staging") == .review)
    #expect(effective.stage(for: "QA Passed") == .verify)
}

/// 합친 뒤에도 원본은 그대로다 — 저장된 사용자 매핑을 오염시키면 안 된다.
@Test func mergingDoesNotMutateTheOriginal() {
    let user = WorkflowMap(statusToStage: ["Done": .done])
    _ = user.merging(["Merged to Staging": .active])
    #expect(user.statusToStage == ["Done": .done])
}

@Test func mergingWithNothingChangesNothing() {
    let user = WorkflowMap(statusToStage: ["Done": .done])
    #expect(user.merging([:]) == user)
}

/// 폴백(②)만 모은다. 미매핑(③)은 단계를 모르므로 실효 맵에 넣을 수 없다 —
/// 넣으면 추측으로 점수를 주는 셈이다.
@Test func resolvedFallbacksExcludeUnmappedAndMapped() {
    let entries = [
        JiraStatusCatalogEntry(id: "10071", name: "Merged to Staging", categoryKey: "indeterminate"),
        JiraStatusCatalogEntry(id: "10016", name: "In Progress", categoryKey: "indeterminate"),
    ]
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: entries)

    _ = catalog.stage(forId: "10071", name: "Merged to Staging")   // ② 폴백
    _ = catalog.stage(forId: "99999", name: "GhostStatus")         // ③ 미매핑
    _ = catalog.stage(forId: "10016", name: "In Progress")         // ① 매핑됨

    #expect(catalog.resolvedFallbacks == ["Merged to Staging": .active])
}

/// 폴백이 실제로 XP를 만든다 — 이 태스크의 존재 이유다.
@Test func fallbackStageActuallyScores() {
    let entries = [JiraStatusCatalogEntry(id: "10071", name: "Merged to Staging",
                                          categoryKey: "indeterminate")]
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: entries)
    _ = catalog.stage(forId: "10071", name: "Merged to Staging")

    // demoWorkflow만으로는 "Merged to Staging"이 nil이라 전이 XP가 0이다.
    #expect(demoWorkflow.stage(for: "Merged to Staging") == nil)

    let effective = demoWorkflow.merging(catalog.resolvedFallbacks)
    #expect(effective.stage(for: "Merged to Staging") == .active)
}
