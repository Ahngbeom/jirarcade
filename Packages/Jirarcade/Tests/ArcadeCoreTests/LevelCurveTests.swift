import Testing
@testable import ArcadeCore

private let curve = LevelCurve(rules: .default)

@Test(arguments: [(5, 1_812), (10, 6_310), (20, 21_972)])
func thresholdsMatchSpec(level: Int, expected: Int) {
    #expect(curve.threshold(forLevel: level) == expected)
}

@Test func levelOneIsTheFloor() {
    #expect(curve.level(forTotalXP: 0) == 1)
    #expect(curve.level(forTotalXP: 50) == 1)
}

@Test(arguments: [(1_812, 5), (6_310, 10), (21_972, 20)])
func totalXPResolvesToLevel(xp: Int, expected: Int) {
    #expect(curve.level(forTotalXP: xp) == expected)
}

/// threshold와 level은 서로의 역함수여야 한다.
/// 이 불변식이 깨지면 "레벨 20 임계값을 정확히 채웠는데 레벨 19로 표시되는" 상태가 생긴다.
@Test func thresholdAndLevelAreInverse() {
    for n in 1...30 {
        #expect(curve.level(forTotalXP: curve.threshold(forLevel: n)) == n, "레벨 \(n)")
    }
}

@Test func levelIsMonotonicInXP() {
    var last = 0
    for xp in stride(from: 0, through: 25_000, by: 250) {
        let level = curve.level(forTotalXP: xp)
        #expect(level >= last)
        last = level
    }
}

@Test func progressReportsPositionWithinTheLevel() {
    let level5 = curve.threshold(forLevel: 5)
    let level6 = curve.threshold(forLevel: 6)
    let progress = curve.progress(forTotalXP: level5 + 100)
    #expect(progress.level == 5)
    #expect(progress.xpIntoLevel == 100)
    #expect(progress.xpForNextLevel == level6 - level5)
}
