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

/// 설정 JSON은 사용자가 편집하고 디스크에 남는다. 나중에 규칙을 추가하면 예전에 저장된
/// 파일에는 그 키가 없는데, Swift 합성 디코더는 키가 없으면 실패한다 — 규칙을 하나 늘렸다고
/// 사용자의 설정이 통째로 안 읽히면 안 된다. 없는 키는 기본값으로 채운다.
@Test func decodingToleratesMissingKeysFromOlderVersions() throws {
    // 백필 필드가 없던 시절의 설정 파일
    let legacy = """
    { "staleDays": 7, "bossDays": 21, "raidDays": 45, "wipLimit": 5 }
    """
    let decoded = try JSONDecoder().decode(RuleSet.self, from: Data(legacy.utf8))

    #expect(decoded.staleDays == 7, "적혀 있던 값은 살아남는다")
    #expect(decoded.wipLimit == 5)
    #expect(decoded.awardsOnlyOwnTransitions == RuleSet.default.awardsOnlyOwnTransitions,
            "없던 키는 기본값으로 채운다")
    #expect(decoded.seasonDays == RuleSet.default.seasonDays)
}

/// 극단적으로 빈 객체도 전부 기본값으로 열려야 한다 — 설정 파일이 잘렸을 때의 방어선이다.
@Test func decodingAnEmptyObjectYieldsDefaults() throws {
    let decoded = try JSONDecoder().decode(RuleSet.self, from: Data("{}".utf8))
    #expect(decoded == RuleSet.default)
}
