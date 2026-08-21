import Testing
import Foundation
@testable import ArcadeCore

/// 눈금은 RuleSet의 등급 경계값이다. 임의의 눈금(0/10/20/30)을 쓰면 화면이 등급과
/// 무관한 눈금을 말하면서 카드에는 BOSS라고 적는 두 개의 설명을 갖게 된다.
@Test func ticksComeFromTheRuleSetBoundaries() {
    let ticks = BoardAxis.ticks(rules: .default)

    #expect(ticks.map(\.days) == [0, 7, 21, 45])
    #expect(ticks.last?.isTerminal == true)
    #expect(ticks.dropLast().allSatisfy { !$0.isTerminal })
}

@Test func ticksAreEvenlySpacedAcrossTheAxis() {
    let positions = BoardAxis.ticks(rules: .default).map(\.position)

    #expect(positions[0] == 0)
    #expect(abs(positions[1] - 1.0 / 3) < 0.0001)
    #expect(abs(positions[2] - 2.0 / 3) < 0.0001)
    #expect(positions[3] == 1)
}

@Test func ticksFollowACustomRuleSet() {
    var rules = RuleSet.default
    rules.staleDays = 3
    rules.bossDays = 10
    rules.raidDays = 20

    #expect(BoardAxis.ticks(rules: rules).map(\.days) == [0, 3, 10, 20])
    #expect(BoardAxis.position(forDays: 10, rules: rules) == 2.0 / 3)
}

/// 각 구간이 축에서 같은 폭을 차지한다. 3일은 0–7 구간의 3/7 지점이므로
/// 축 전체로는 (3/7) × (1/3) ≈ 0.1429다.
@Test func mapsDaysWithinASegmentLinearly() {
    #expect(abs(BoardAxis.position(forDays: 3, rules: .default) - 3.0 / 7 / 3) < 0.0001)
    // 30일은 21–45 구간의 9/24 지점 → 2/3 + (9/24)/3 ≈ 0.7917
    #expect(abs(BoardAxis.position(forDays: 30, rules: .default) - (2.0 / 3 + 9.0 / 24 / 3)) < 0.0001)
}

/// raidDays를 넘는 티켓은 오른쪽 끝에 붙인다. 3년 정체 티켓 하나가 축 전체를 압축해
/// 나머지를 왼쪽 끝에 뭉치게 하는 것을 막는다. 실제 일수는 카드가 그대로 표기한다.
@Test func clampsBeyondTheTerminalBoundary() {
    #expect(BoardAxis.position(forDays: 45, rules: .default) == 1)
    #expect(BoardAxis.position(forDays: 400, rules: .default) == 1)
}

@Test func clampsBelowZero() {
    #expect(BoardAxis.position(forDays: 0, rules: .default) == 0)
    #expect(BoardAxis.position(forDays: -3, rules: .default) == 0)
}

/// RuleSet은 설정 화면에서 JSON으로 편집할 수 있다. 역전되거나 같은 값이 들어와도
/// 위치가 축 밖으로 나가면 안 된다 — 카드가 화면 밖에 그려지거나 0으로 나누게 된다.
@Test func survivesAContradictoryRuleSet() {
    var rules = RuleSet.default
    rules.staleDays = 30
    rules.bossDays = 10
    rules.raidDays = 5

    let ticks = BoardAxis.ticks(rules: rules)
    #expect(ticks.count == 4)
    #expect(ticks.map(\.days) == ticks.map(\.days).sorted())

    for days in [-5, 0, 1, 10, 30, 100] {
        let position = BoardAxis.position(forDays: days, rules: rules)
        #expect(position >= 0 && position <= 1, "days=\(days) → \(position)")
    }
}
