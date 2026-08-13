import Testing
import Foundation
@testable import ArcadeCore

@Test func issueIdentityIsTheKey() {
    let a = issue(key: "DEMO-1", status: "In Progress")
    #expect(a.id == "DEMO-1")
}

@Test func eventKindRoundTripsThroughRawValue() {
    for kind in EventKind.allCases {
        #expect(EventKind(rawValue: kind.rawValue) == kind)
    }
}

@Test func scoredEventCarriesItsEvent() {
    let event = DomainEvent(issueKey: "DEMO-1", kind: .touched,
                            fromStatus: nil, toStatus: nil,
                            observedAt: iso("2026-08-12T09:00:00Z"),
                            actorAccountId: "acc-1")
    let scored = ScoredEvent(event: event, xp: 40)
    #expect(scored.event.issueKey == "DEMO-1")
    #expect(scored.xp == 40)
}
