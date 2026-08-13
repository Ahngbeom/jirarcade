import Testing
import Foundation
@testable import ArcadeCore

private let now = iso("2026-08-12T00:00:00Z")
private let classifier = StagnationClassifier(rules: .default)

@Test func prefersStatusEnteredAtOverJiraUpdatedAt() {
    let stagnant = classifier.daysStagnant(
        statusEnteredAt: now.addingTimeInterval(-days(30)),
        jiraUpdatedAt: now.addingTimeInterval(-days(1)),
        now: now
    )
    #expect(stagnant == 30)
}

@Test func fallsBackToJiraUpdatedAtWhenNoHistory() {
    let stagnant = classifier.daysStagnant(
        statusEnteredAt: nil,
        jiraUpdatedAt: now.addingTimeInterval(-days(6)),
        now: now
    )
    #expect(stagnant == 6)
}

@Test func approximateFlagTracksMissingHistory() {
    #expect(classifier.isApproximate(statusEnteredAt: nil) == true)
    #expect(classifier.isApproximate(statusEnteredAt: now) == false)
}

@Test(arguments: [
    (0, StagnationTier.fresh),
    (6, StagnationTier.fresh),
    (7, StagnationTier.stale),
    (20, StagnationTier.stale),
    (21, StagnationTier.boss),
    (44, StagnationTier.boss),
    (45, StagnationTier.raid),
    (120, StagnationTier.raid),
])
func classifiesAtBoundaries(elapsed: Int, expected: StagnationTier) {
    let tier = classifier.classify(
        statusEnteredAt: now.addingTimeInterval(-days(Double(elapsed))),
        jiraUpdatedAt: now,
        now: now
    )
    #expect(tier == expected)
}

@Test func futureTimestampsClampToZero() {
    let stagnant = classifier.daysStagnant(
        statusEnteredAt: now.addingTimeInterval(days(3)),
        jiraUpdatedAt: now,
        now: now
    )
    #expect(stagnant == 0)
}

@Test func tiersAreOrdered() {
    #expect(StagnationTier.fresh < StagnationTier.stale)
    #expect(StagnationTier.stale < StagnationTier.boss)
    #expect(StagnationTier.boss < StagnationTier.raid)
}
