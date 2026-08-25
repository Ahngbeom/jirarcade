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

    // 백필과 시즌
    /// 내가 직접 옮긴 전이에만 XP를 준다. changelog의 author로 판별한다.
    /// false로 두면 담당 티켓의 모든 전이가 XP 대상이 된다.
    public var awardsOnlyOwnTransitions: Bool
    /// 시즌 XP 바가 세는 기간(일). 고정 시즌이 아니라 `now - seasonDays`부터의
    /// 롤링 윈도우다 — 리셋 절벽을 만들지 않기 위해서다.
    public var seasonDays: Int

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
        levelBase: 100, levelExponent: 1.8,
        awardsOnlyOwnTransitions: true,
        seasonDays: 30
    )
}

extension RuleSet {
    /// 없는 키는 기본값으로 채운다.
    ///
    /// 설정 JSON은 사용자가 편집하고 디스크에 남는다. 규칙을 하나 추가할 때마다 예전에
    /// 저장된 파일이 열리지 않는다면, 규칙을 늘릴 때마다 사용자 설정이 초기화되는 셈이다.
    /// 쓰기(`Encodable`)는 합성 그대로 두어 항상 전체 키를 내보낸다 — 관대해야 하는 건
    /// 읽는 쪽뿐이다.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RuleSet.default
        func int(_ key: CodingKeys, _ fallback: Int) throws -> Int {
            try c.decodeIfPresent(Int.self, forKey: key) ?? fallback
        }
        func dbl(_ key: CodingKeys, _ fallback: Double) throws -> Double {
            try c.decodeIfPresent(Double.self, forKey: key) ?? fallback
        }
        func bool(_ key: CodingKeys, _ fallback: Bool) throws -> Bool {
            try c.decodeIfPresent(Bool.self, forKey: key) ?? fallback
        }

        // 아래는 저장 프로퍼티 선언 순서 그대로다. 필드를 추가하면 여기에도 한 줄 는다 —
        // 잊으면 그 필드만 조용히 기본값으로 고정되므로, 새 필드마다 테스트를 함께 추가할 것.
        self.init(
            staleDays: try int(.staleDays, d.staleDays),
            bossDays: try int(.bossDays, d.bossDays),
            raidDays: try int(.raidDays, d.raidDays),
            wakeBaseXP: try int(.wakeBaseXP, d.wakeBaseXP),
            wakeDivisorDays: try dbl(.wakeDivisorDays, d.wakeDivisorDays),
            wakeMaxMultiplier: try dbl(.wakeMaxMultiplier, d.wakeMaxMultiplier),
            forwardMultiplier: try dbl(.forwardMultiplier, d.forwardMultiplier),
            hygieneMaxScore: try int(.hygieneMaxScore, d.hygieneMaxScore),
            wipLimit: try int(.wipLimit, d.wipLimit),
            wipPenalty: try int(.wipPenalty, d.wipPenalty),
            zombieDays: try int(.zombieDays, d.zombieDays),
            zombiePenalty: try int(.zombiePenalty, d.zombiePenalty),
            ghostPenalty: try int(.ghostPenalty, d.ghostPenalty),
            hygieneBonusThreshold: try int(.hygieneBonusThreshold, d.hygieneBonusThreshold),
            hygieneBonusXP: try int(.hygieneBonusXP, d.hygieneBonusXP),
            maxHP: try int(.maxHP, d.maxHP),
            streakStepBonus: try dbl(.streakStepBonus, d.streakStepBonus),
            streakCapDays: try int(.streakCapDays, d.streakCapDays),
            countsWeekends: try bool(.countsWeekends, d.countsWeekends),
            dueBonusPerDay: try int(.dueBonusPerDay, d.dueBonusPerDay),
            dueBonusCap: try int(.dueBonusCap, d.dueBonusCap),
            dailyXPCap: try int(.dailyXPCap, d.dailyXPCap),
            duplicateWindowHours: try dbl(.duplicateWindowHours, d.duplicateWindowHours),
            revertWindowMinutes: try dbl(.revertWindowMinutes, d.revertWindowMinutes),
            levelBase: try dbl(.levelBase, d.levelBase),
            levelExponent: try dbl(.levelExponent, d.levelExponent),
            awardsOnlyOwnTransitions: try bool(.awardsOnlyOwnTransitions, d.awardsOnlyOwnTransitions),
            seasonDays: try int(.seasonDays, d.seasonDays)
        )
    }
}
