import Testing
import Foundation
@testable import ArcadeCore

private var utc: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private let calc = StreakCalculator(rules: .default, calendar: utc)

// 2026-08-10 월, 08-11 화, 08-12 수, 08-13 목, 08-14 금, 08-15 토, 08-17 월
private func day(_ d: String) -> Date { iso("2026-08-\(d)T09:00:00Z") }

@Test func firstCheckInStartsStreakAtOne() {
    let state = calc.checkIn(StreakState.initial, at: day("10"))
    #expect(state.currentStreak == 1)
    #expect(state.longestStreak == 1)
}

@Test func consecutiveWeekdaysExtendTheStreak() {
    var state = calc.checkIn(StreakState.initial, at: day("10"))
    state = calc.checkIn(state, at: day("11"))
    state = calc.checkIn(state, at: day("12"))
    #expect(state.currentStreak == 3)
}

@Test func secondCheckInSameDayDoesNotDoubleCount() {
    var state = calc.checkIn(StreakState.initial, at: day("10"))
    state = calc.checkIn(state, at: iso("2026-08-10T18:00:00Z"))
    #expect(state.currentStreak == 1)
}

@Test func weekendGapDoesNotBreakTheStreak() {
    var state = calc.checkIn(StreakState.initial, at: day("14"))  // 금
    state = calc.checkIn(state, at: day("17"))                    // 다음 월
    #expect(state.currentStreak == 2)
    #expect(state.freezesAvailable == 1, "주말은 결석이 아니므로 동결을 쓰지 않는다")
}

@Test func oneMissedWeekdayConsumesAFreeze() {
    var state = calc.checkIn(StreakState.initial, at: day("10"))  // 월
    state = calc.checkIn(state, at: day("12"))                    // 수 (화 결석)
    #expect(state.currentStreak == 2)
    #expect(state.freezesAvailable == 0)
}

@Test func missingTwoWeekdaysResetsTheStreak() {
    var state = calc.checkIn(StreakState.initial, at: day("10"))  // 월
    state = calc.checkIn(state, at: day("13"))                    // 목 (화·수 결석)
    #expect(state.currentStreak == 1)
}

@Test func freezeRefillsInANewWeek() {
    var state = calc.checkIn(StreakState.initial, at: day("10"))  // 월
    state = calc.checkIn(state, at: day("12"))                    // 동결 소모
    #expect(state.freezesAvailable == 0)
    state = calc.checkIn(state, at: day("17"))                    // 다음 주 월
    #expect(state.freezesAvailable == 1)
}

@Test func longestStreakRemembersThePeak() {
    var state = calc.checkIn(StreakState.initial, at: day("10"))
    state = calc.checkIn(state, at: day("11"))
    state = calc.checkIn(state, at: day("12"))
    state = calc.checkIn(state, at: day("17"))  // 목·금 결석 → 리셋
    #expect(state.currentStreak == 1)
    #expect(state.longestStreak == 3)
}

@Test(arguments: [(0, 1.0), (1, 1.05), (7, 1.35), (14, 1.70), (30, 1.70)])
func multiplierCapsAtFourteenDays(streak: Int, expected: Double) {
    #expect(abs(calc.multiplier(forStreak: streak) - expected) < 0.0001)
}
