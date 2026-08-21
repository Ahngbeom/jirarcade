import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

private let entries = [
    JiraStatusCatalogEntry(id: "10009", name: "To Do", categoryKey: "new"),
    JiraStatusCatalogEntry(id: "10016", name: "In Progress", categoryKey: "indeterminate"),
    JiraStatusCatalogEntry(id: "10071", name: "Merged to Staging", categoryKey: "indeterminate"),
    JiraStatusCatalogEntry(id: "10013", name: "QA Done", categoryKey: "indeterminate"),
    JiraStatusCatalogEntry(id: "10011", name: "Done", categoryKey: "done"),
]

/// ① 현재 워크플로 매핑이 최우선이다.
@Test func mappedStatusWinsOverFallback() {
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: entries)
    #expect(catalog.stage(forId: "10016", name: "In Progress") == .mapped(.active))
}

/// ② 매핑에 없으면 statusCategory로 떨어뜨린다. 0점으로 버리는 것보다 방향이 맞다(스펙 §5).
@Test func unmappedStatusFallsBackToCategory() {
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: entries)
    #expect(catalog.stage(forId: "10071", name: "Merged to Staging") == .fallback(.active))

    // 이름에 "Done"이 들어가지만 statusCategory는 indeterminate다. 이름으로 단계를
    // 추측하면 틀리고 카테고리로 봐야 맞는 케이스 — 폴백이 이름이 아니라 ID로 찾은
    // 엔트리의 카테고리를 쓰는 이유다.
    #expect(catalog.stage(forId: "10013", name: "QA Done") == .fallback(.active))

    // demoWorkflow에 있는 이름은 카탈로그에 있어도 ①이 먼저 잡는다.
    #expect(catalog.stage(forId: "10009", name: "To Do") == .mapped(.backlog))
    #expect(catalog.stage(forId: "10011", name: "Done") == .mapped(.done))
}

/// ③ 카탈로그에도 없으면 미매핑이다. 임의 단계로 추측하지 않는다.
@Test func unknownStatusIsUnmapped() {
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: entries)
    #expect(catalog.stage(forId: "99999", name: "사라진상태") == .unmapped("사라진상태"))
}

/// 카탈로그 조회는 ID로 한다. 상태 이름이 바뀌어도 과거 changelog의 이름으로
/// 조회했을 때 여전히 찾아진다.
@Test func catalogLookupSurvivesARename() {
    let renamed = [JiraStatusCatalogEntry(id: "10071", name: "Staged", categoryKey: "indeterminate")]
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: renamed)
    // changelog에는 옛 이름이 박혀 있지만 ID는 그대로다.
    #expect(catalog.stage(forId: "10071", name: "Merged to Staging") == .fallback(.active))
}

/// 폴백으로 처리한 상태를 모아둔다 — 백필이 끝나면 매핑 마법사 후보가 된다(스펙 §5).
@Test func fallbackAndUnmappedNamesAreCollected() {
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: entries)
    _ = catalog.stage(forId: "10071", name: "Merged to Staging")
    _ = catalog.stage(forId: "99999", name: "사라진상태")
    _ = catalog.stage(forId: "10016", name: "In Progress")   // 매핑됨 — 수집 대상 아님

    #expect(catalog.unmappedNames.contains("Merged to Staging"))
    #expect(catalog.unmappedNames.contains("사라진상태"))
    #expect(!catalog.unmappedNames.contains("In Progress"))
}

/// 이름도 ID도 없는 status 변경이 마법사 후보에 빈 항목을 만들면 안 된다.
/// changelog의 toString이 비어 오는 경우가 실제로 있다.
@Test func namelessStatusIsNotCollected() {
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: entries)
    #expect(catalog.stage(forId: nil, name: nil) == .unmapped(""))
    #expect(catalog.unmappedNames.isEmpty)
}

/// 카탈로그 조회에 실패해 entries가 비어도 ①③만으로 degraded 동작해야 한다(스펙 §8).
@Test func emptyCatalogStillUsesTheWorkflowMap() {
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: [])
    #expect(catalog.stage(forId: "10016", name: "In Progress") == .mapped(.active))
    #expect(catalog.stage(forId: "10071", name: "Merged to Staging") == .unmapped("Merged to Staging"))
}

@Test(arguments: [("new", Stage.backlog), ("indeterminate", Stage.active), ("done", Stage.done)])
func categoryKeysMapToStages(key: String, expected: Stage) {
    let catalog = StatusCatalog(
        workflow: WorkflowMap(statusToStage: [:]),
        entries: [JiraStatusCatalogEntry(id: "1", name: "X", categoryKey: key)]
    )
    #expect(catalog.stage(forId: "1", name: "X") == .fallback(expected))
}

/// 이름 없이 ID만 오는 항목도 매핑된 상태로 해석돼야 한다.
/// 카테고리 폴백에 맡기면 .review(order 2)가 .active(order 1)로 한 칸 어긋나
/// 전진 판정이 뒤집힌다.
@Test func idOnlyItemStillResolvesThroughTheWorkflowMap() {
    let catalog = StatusCatalog(
        workflow: demoWorkflow,
        entries: [JiraStatusCatalogEntry(id: "10020", name: "In Review",
                                         categoryKey: "indeterminate")]
    )
    #expect(catalog.stage(forId: "10020", name: nil) == .mapped(.review))
    #expect(catalog.unmappedNames.isEmpty, "매핑된 상태는 마법사 후보가 아니다")
}

/// 폴백으로 떨어질 때도 라벨은 숫자 ID가 아니라 이름이어야 한다 —
/// 마법사가 만든 매핑의 키가 되고, 그 키는 이름으로 조회된다.
@Test func fallbackLabelUsesTheCatalogNameNotTheId() {
    let catalog = StatusCatalog(
        workflow: demoWorkflow,
        entries: [JiraStatusCatalogEntry(id: "10071", name: "Merged to Staging",
                                         categoryKey: "indeterminate")]
    )
    #expect(catalog.stage(forId: "10071", name: nil) == .fallback(.active))
    #expect(catalog.unmappedNames == ["Merged to Staging"])
}

/// 실제 Jira는 statusCategory.key로 "undefined"(No Category)를 돌려주는 항목이 있다.
/// 모르는 카테고리는 추측하지 않고 미매핑으로 둔다 — 추측하면 0점이어야 할 상태가
/// 조용히 점수를 받는다.
@Test func unknownCategoryKeyIsNotGuessed() {
    let catalog = StatusCatalog(
        workflow: demoWorkflow,
        entries: [JiraStatusCatalogEntry(id: "10099", name: "Uncategorized",
                                         categoryKey: "undefined")]
    )
    #expect(catalog.stage(forId: "10099", name: "Uncategorized") == .unmapped("Uncategorized"))
}

/// 채점이 실제로 읽는 프로퍼티다. 미매핑에 단계를 주는 구현으로 바뀌어도
/// 지금 테스트는 전부 통과한다(변이 생존 확인됨).
@Test func stageAccessorReflectsTheResolutionKind() {
    #expect(StageResolution.mapped(.review).stage == .review)
    #expect(StageResolution.fallback(.active).stage == .active)
    #expect(StageResolution.unmapped("X").stage == nil)
}
