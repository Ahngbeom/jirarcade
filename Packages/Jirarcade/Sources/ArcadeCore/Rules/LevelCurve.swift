import Foundation

public struct LevelProgress: Sendable, Equatable {
    public let level: Int
    public let xpIntoLevel: Int
    public let xpForNextLevel: Int
}

/// 누적 XP와 레벨의 상호 변환. threshold(n) = base × n^exponent 이며
/// level(xp)는 그 역함수를 내림한 값이다(최소 1).
public struct LevelCurve: Sendable {
    private let rules: RuleSet

    public init(rules: RuleSet) {
        self.rules = rules
    }

    /// 레벨 N에 도달하는 데 필요한 누적 XP.
    /// 반올림이 아니라 **올림**을 쓴다 — 반올림하면 threshold(N)이 실제 임계보다 낮아질 수 있고
    /// (예: 21971.21 → 21971), 그 값을 level()에 넣으면 N-1이 나와 레벨 경계가 어긋난다.
    public func threshold(forLevel level: Int) -> Int {
        guard level > 0 else { return 0 }
        return Int((rules.levelBase * pow(Double(level), rules.levelExponent)).rounded(.up))
    }

    public func level(forTotalXP xp: Int) -> Int {
        guard xp > 0 else { return 1 }
        let raw = pow(Double(xp) / rules.levelBase, 1 / rules.levelExponent)
        // 부동소수 오차로 경계에서 한 단계 낮게 떨어지는 것을 막는다.
        let adjusted = (raw + 1e-9).rounded(.down)
        return max(1, Int(adjusted))
    }

    public func progress(forTotalXP xp: Int) -> LevelProgress {
        let current = level(forTotalXP: xp)
        let floorXP = threshold(forLevel: current)
        let nextXP = threshold(forLevel: current + 1)
        return LevelProgress(
            level: current,
            xpIntoLevel: max(0, xp - floorXP),
            xpForNextLevel: max(1, nextXP - floorXP)
        )
    }
}
