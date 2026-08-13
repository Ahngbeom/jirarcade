import Foundation

public struct StreakState: Sendable, Equatable {
    public var currentStreak: Int
    public var longestStreak: Int
    public var lastCheckInDay: Date?
    public var freezesAvailable: Int
    /// 동결을 마지막으로 보충한 주의 시작일. 주가 바뀌면 다시 채운다.
    public var freezeRefilledWeek: Date?

    public init(
        currentStreak: Int = 0, longestStreak: Int = 0, lastCheckInDay: Date? = nil,
        freezesAvailable: Int = 1, freezeRefilledWeek: Date? = nil
    ) {
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.lastCheckInDay = lastCheckInDay
        self.freezesAvailable = freezesAvailable
        self.freezeRefilledWeek = freezeRefilledWeek
    }

    public static let initial = StreakState()
}

public struct StreakCalculator: Sendable {
    private let rules: RuleSet
    private let calendar: Calendar

    public init(rules: RuleSet, calendar: Calendar) {
        self.rules = rules
        self.calendar = calendar
    }

    public func multiplier(forStreak streak: Int) -> Double {
        1 + Double(min(max(streak, 0), rules.streakCapDays)) * rules.streakStepBonus
    }

    public func checkIn(_ state: StreakState, at now: Date) -> StreakState {
        var next = state
        let today = calendar.startOfDay(for: now)

        next = refillFreezeIfNewWeek(next, today: today)

        guard let last = state.lastCheckInDay else {
            next.currentStreak = 1
            next.longestStreak = max(next.longestStreak, 1)
            next.lastCheckInDay = today
            return next
        }

        let lastDay = calendar.startOfDay(for: last)
        if lastDay == today { return next }   // 같은 날 재체크인은 무시

        let missed = countedDaysBetween(lastDay, and: today) - 1

        if missed <= 0 {
            next.currentStreak = state.currentStreak + 1
        } else if missed == 1 && next.freezesAvailable > 0 {
            next.freezesAvailable -= 1
            next.currentStreak = state.currentStreak + 1
        } else {
            next.currentStreak = 1
        }

        next.longestStreak = max(next.longestStreak, next.currentStreak)
        next.lastCheckInDay = today
        return next
    }

    /// 두 날짜 사이의 "세는 날" 수. 주말을 세지 않는 설정이면 토·일은 제외한다.
    /// 같은 날이면 0, 연속한 세는 날이면 1을 돌려준다.
    private func countedDaysBetween(_ from: Date, and to: Date) -> Int {
        guard to > from else { return 0 }
        var count = 0
        var cursor = from
        while cursor < to {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            if isCounted(cursor) { count += 1 }
        }
        return count
    }

    private func isCounted(_ date: Date) -> Bool {
        if rules.countsWeekends { return true }
        return !calendar.isDateInWeekend(date)
    }

    private func refillFreezeIfNewWeek(_ state: StreakState, today: Date) -> StreakState {
        var next = state
        guard let week = calendar.dateInterval(of: .weekOfYear, for: today)?.start else { return next }
        if next.freezeRefilledWeek != week {
            next.freezeRefilledWeek = week
            next.freezesAvailable = 1
        }
        return next
    }
}
