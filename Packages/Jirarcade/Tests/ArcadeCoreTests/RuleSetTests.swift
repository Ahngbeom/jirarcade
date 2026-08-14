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

/// 백필은 changelog의 author로 실행자를 알 수 있다. 남이 옮긴 전이를 내 XP로 세면
/// "내가 업무를 처리하는 행동을 유도한다"는 스펙의 목적과 어긋난다(스펙 §4.2).
@Test func defaultRuleSetAwardsOnlyOwnTransitions() {
    #expect(RuleSet.default.awardsOnlyOwnTransitions == true)
}

/// 시즌은 롤링 윈도우다. 길이를 RuleSet에 두어 사용자가 조정할 수 있게 한다(스펙 §6).
@Test func defaultSeasonIsThirtyDays() {
    #expect(RuleSet.default.seasonDays == 30)
}
