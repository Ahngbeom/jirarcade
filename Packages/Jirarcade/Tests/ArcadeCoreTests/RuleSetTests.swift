import Testing
import Foundation
@testable import ArcadeCore

@Test func defaultRuleSetMatchesSpec() {
    let rules = RuleSet.default
    #expect(rules.staleDays == 7)
    #expect(rules.bossDays == 21)
    #expect(rules.raidDays == 45)
    #expect(rules.wipLimit == 5)
    #expect(rules.dailyXPCap == 1_200)
    #expect(rules.levelExponent == 1.8)
}

@Test func ruleSetSurvivesJSONRoundTrip() throws {
    let data = try JSONEncoder().encode(RuleSet.default)
    let decoded = try JSONDecoder().decode(RuleSet.self, from: data)
    #expect(decoded == RuleSet.default)
}
