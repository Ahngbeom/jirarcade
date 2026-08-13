import Foundation

/// 게임 규칙 상수 전체. 코드에 숫자를 하드코딩하지 않고 이 구조체에서만 읽는다.
/// Codable이므로 설정 화면에서 JSON으로 편집하고 재집계할 수 있다.
public struct RuleSet: Codable, Sendable, Equatable {
    // 정체 등급 경계 (일)
    public var staleDays: Int
    public var bossDays: Int
    public var raidDays: Int

    // 깨우기 XP
    public var wakeBaseXP: Int
    public var wakeDivisorDays: Double
    public var wakeMaxMultiplier: Double
    public var forwardMultiplier: Double

    // 위생 감점
    public var hygieneMaxScore: Int
    public var wipLimit: Int
    public var wipPenalty: Int
    public var zombieDays: Int
    public var zombiePenalty: Int
    public var ghostPenalty: Int
    public var hygieneBonusThreshold: Int
    public var hygieneBonusXP: Int

    // 마감 방어
    public var maxHP: Int

    // 연속 기록
    public var streakStepBonus: Double
    public var streakCapDays: Int
    public var countsWeekends: Bool

    // 마감 보너스
    public var dueBonusPerDay: Int
    public var dueBonusCap: Int

    // 어뷰징 방지
    public var dailyXPCap: Int
    public var duplicateWindowHours: Double
    public var revertWindowMinutes: Double

    // 레벨 곡선
    public var levelBase: Double
    public var levelExponent: Double

    public static let `default` = RuleSet(
        staleDays: 7, bossDays: 21, raidDays: 45,
        wakeBaseXP: 40, wakeDivisorDays: 14, wakeMaxMultiplier: 4.0, forwardMultiplier: 1.5,
        hygieneMaxScore: 100,
        wipLimit: 5, wipPenalty: 8, zombieDays: 7, zombiePenalty: 6, ghostPenalty: 10,
        hygieneBonusThreshold: 80, hygieneBonusXP: 50,
        maxHP: 3,
        streakStepBonus: 0.05, streakCapDays: 14, countsWeekends: false,
        dueBonusPerDay: 10, dueBonusCap: 80,
        dailyXPCap: 1_200, duplicateWindowHours: 24, revertWindowMinutes: 10,
        levelBase: 100, levelExponent: 1.8
    )
}
