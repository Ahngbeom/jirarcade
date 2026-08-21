import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

private let entries = [
    JiraStatusCatalogEntry(id: "10009", name: "To Do", categoryKey: "new"),
    JiraStatusCatalogEntry(id: "10016", name: "In Progress", categoryKey: "indeterminate"),
    JiraStatusCatalogEntry(id: "10071", name: "Merged to Staging", categoryKey: "indeterminate"),
    JiraStatusCatalogEntry(id: "10013", name: "검수Done", categoryKey: "indeterminate"),
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
    #expect(catalog.stage(forId: "10013", name: "검수Done") == .fallback(.active))

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
