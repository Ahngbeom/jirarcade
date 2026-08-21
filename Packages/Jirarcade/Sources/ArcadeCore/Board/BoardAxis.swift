import Foundation

/// 축 위의 눈금 하나.
public struct AxisTick: Sendable, Equatable {
    public let days: Int
    /// 축 위 0.0…1.0 위치.
    public let position: Double
    /// 마지막 눈금인가. 그 너머가 접혀 있으므로 화면은 "45d+"처럼 그린다.
    public let isTerminal: Bool

    public init(days: Int, position: Double, isTerminal: Bool) {
        self.days = days
        self.position = position
        self.isTerminal = isTerminal
    }
}

/// 정체일을 축 위 위치로 옮긴다.
public enum BoardAxis {
    /// 눈금은 `RuleSet`의 등급 경계값이다: 0 / staleDays / bossDays / raidDays.
    /// 설정에서 규칙을 고치면 축이 따라 움직인다 — 부작용이 아니라 의도다.
    public static func ticks(rules: RuleSet) -> [AxisTick] {
        let bounds = boundaries(rules: rules)
        let last = bounds.count - 1
        return bounds.enumerated().map { index, days in
            AxisTick(days: days,
                     position: Double(index) / Double(last),
                     isTerminal: index == last)
        }
    }

    /// 구간별 선형. 각 눈금 구간이 축에서 **같은 폭**을 차지한다.
    ///
    /// 단순 선형(`days / raidDays`)이 아닌 이유: 0–7일 구간이 축의 15%에 불과한데
    /// 실제 티켓은 대부분 그 구간에 있다. 다수가 왼쪽 끝에 뭉쳐 서로를 가리고 화면의
    /// 85%가 빈다. 등급이 갈리는 구간을 넓게 펼치는 것이 읽고 싶은 것에 맞는 배분이다 —
    /// 45일과 50일의 차이는 이미 둘 다 raid라는 사실 앞에서 작고, 5일과 10일은 등급이 갈린다.
    public static func position(forDays days: Int, rules: RuleSet) -> Double {
        let bounds = boundaries(rules: rules)
        let segments = bounds.count - 1
        guard days > bounds[0] else { return 0 }
        guard days < bounds[segments] else { return 1 }

        for index in 0..<segments where days < bounds[index + 1] {
            let lower = bounds[index], upper = bounds[index + 1]
            let withinSegment = Double(days - lower) / Double(upper - lower)
            return (Double(index) + withinSegment) / Double(segments)
        }
        return 1
    }

    /// 0 / staleDays / bossDays / raidDays를 **단조 증가하도록** 정리한다.
    ///
    /// `RuleSet`은 설정 화면에서 JSON으로 편집할 수 있으므로 역전되거나 같은 값이 올 수
    /// 있다. 그대로 두면 구간 폭이 0이 되어 0으로 나누거나, 음수가 되어 위치가 축 밖으로
    /// 나간다 — 카드가 화면 밖에 그려진다. 앞 경계보다 최소 1 크게 밀어 그 두 경우를 막는다.
    private static func boundaries(rules: RuleSet) -> [Int] {
        var values = [0, rules.staleDays, rules.bossDays, rules.raidDays]
        for index in 1..<values.count {
            values[index] = max(values[index], values[index - 1] + 1)
        }
        return values
    }
}
