import Testing
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
