import Foundation

/// Jira의 `duedate`는 시각이 없는 날짜다. `JiraKit`은 이를 결정적으로 파싱하기 위해
/// UTC 자정으로 읽는다 — 그 자체는 옳지만, 그대로 `Date`끼리 비교하면 시간대가 앞선
/// 사용자에게 마감이 오프셋만큼 일찍 지난 것으로 보인다(KST 기준 마감일 당일 오전 9시부터).
///
/// 스펙 §8.6은 "타임존이 바뀌어도 하루의 정의가 흔들리지 않게" 로컬 달력으로 계산하라고 한다.
/// 그래서 마감 비교는 전부 이 타입을 거쳐 **로컬 달력의 날짜 단위**로 한다.
enum DueDate {
    /// `duedate`가 파싱된 달력. 날짜 성분을 되꺼내려면 파싱할 때와 같은 시간대여야 한다.
    private static let parsed: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// 마감일이 가리키는 **로컬 달력의 그 날 시작**. 성분을 복원할 수 없으면 nil.
    static func localStartOfDay(_ due: Date, calendar: Calendar) -> Date? {
        let parts = parsed.dateComponents([.year, .month, .day], from: due)
        return calendar.date(from: DateComponents(
            year: parts.year, month: parts.month, day: parts.day
        ))
    }

    /// 마감일이 `now`가 속한 날보다 앞서는가. 마감일 **당일은 아직 지나지 않은 것**으로 본다.
    static func isOverdue(_ due: Date, now: Date, calendar: Calendar) -> Bool {
        guard let dueDay = localStartOfDay(due, calendar: calendar) else { return false }
        return dueDay < calendar.startOfDay(for: now)
    }

    /// 마감까지 남은 날 수. 마감 당일이면 0, 이미 지났으면 음수.
    static func daysRemaining(until due: Date, from now: Date, calendar: Calendar) -> Int {
        guard let dueDay = localStartOfDay(due, calendar: calendar) else { return 0 }
        let today = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: today, to: dueDay).day ?? 0
    }
}
