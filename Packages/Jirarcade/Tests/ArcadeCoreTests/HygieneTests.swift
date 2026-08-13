import Testing
import Foundation
@testable import ArcadeCore

private var utc: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private var kst: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return cal
}

private let now = iso("2026-08-12T00:00:00Z")
private let calc = HygieneCalculator(rules: .default, workflow: demoWorkflow, calendar: utc)

/// 좀비 판정을 피하려면 최근에 갱신된 상태여야 한다.
private func activeIssues(_ count: Int) -> [ObservedIssue] {
    (1...count).map {
        issue(key: "DEMO-\($0)", status: "In Progress", updated: now.addingTimeInterval(-days(1)))
    }
}

@Test func measuredBaselineScoresExactly44() {
    let report = calc.evaluate(activeIssues(12), now: now)
    #expect(report.wipCount == 12)
    #expect(report.wipPenalty == 56)   // (12 - 5) * 8
    #expect(report.zombieCount == 0)
    #expect(report.ghostCount == 0)
    #expect(report.score == 44)
}

@Test func atOrBelowWIPLimitThereIsNoPenalty() {
    let report = calc.evaluate(activeIssues(5), now: now)
    #expect(report.wipPenalty == 0)
    #expect(report.score == 100)
}

@Test func staleActiveIssuesCountAsZombies() {
    let fresh = issue(key: "DEMO-1", status: "In Progress", updated: now.addingTimeInterval(-days(1)))
    let zombie = issue(key: "DEMO-2", status: "In Progress", updated: now.addingTimeInterval(-days(9)))
    let report = calc.evaluate([fresh, zombie], now: now)
    #expect(report.zombieCount == 1)
    #expect(report.zombiePenalty == 6)
    #expect(report.score == 94)
}

@Test func onlyActiveStageCanBeAZombie() {
    let idle = issue(key: "DEMO-3", status: "Verifying", updated: now.addingTimeInterval(-days(60)))
    let report = calc.evaluate([idle], now: now)
    #expect(report.zombieCount == 0)
}

@Test func overdueUnfinishedIssuesAreGhosts() {
    let ghost = issue(key: "DEMO-4", status: "To Do",
                      due: now.addingTimeInterval(-days(2)),
                      updated: now)
    let report = calc.evaluate([ghost], now: now)
    #expect(report.ghostCount == 1)
    #expect(report.score == 90)
}

@Test func hpStartsFullAndDropsOnePerOverdueIssue() {
    #expect(calc.evaluate(activeIssues(3), now: now).hp == 3)

    let overdue = (1...2).map {
        issue(key: "DEMO-\($0)", status: "In Progress",
              due: now.addingTimeInterval(-days(1)), updated: now)
    }
    #expect(calc.evaluate(overdue, now: now).hp == 1)
}

@Test func hpNeverGoesBelowZero() {
    let overdue = (1...9).map {
        issue(key: "DEMO-\($0)", status: "In Progress",
              due: now.addingTimeInterval(-days(1)), updated: now)
    }
    #expect(calc.evaluate(overdue, now: now).hp == 0)
}

/// Jira의 duedate는 UTC 자정으로 파싱된다. 날짜로 비교하지 않으면 KST 사용자에게는
/// 마감일 당일 오전 9시부터 유령이 된다 — 스펙 §8.6의 "하루의 정의" 원칙 위반이다.
@Test func aTicketDueTodayIsNotAGhostAtLocalNoon() {
    let seoulCalc = HygieneCalculator(rules: .default, workflow: demoWorkflow, calendar: kst)
    let noonKST = iso("2026-08-13T03:00:00Z")            // 2026-08-13 12:00 KST
    let dueToday = iso("2026-08-13T00:00:00Z")           // duedate "2026-08-13"이 파싱된 값

    let today = issue(key: "DEMO-1", status: "In Progress", due: dueToday, updated: noonKST)
    #expect(seoulCalc.evaluate([today], now: noonKST).ghostCount == 0)
    #expect(seoulCalc.evaluate([today], now: noonKST).hp == 3)
}

/// 그 다음 날 정오에는 유령이 맞다.
@Test func aTicketDueYesterdayIsAGhostAtLocalNoon() {
    let seoulCalc = HygieneCalculator(rules: .default, workflow: demoWorkflow, calendar: kst)
    let noonKST = iso("2026-08-14T03:00:00Z")
    let dueYesterday = iso("2026-08-13T00:00:00Z")

    let late = issue(key: "DEMO-1", status: "In Progress", due: dueYesterday, updated: noonKST)
    #expect(seoulCalc.evaluate([late], now: noonKST).ghostCount == 1)
}

@Test func doneIssuesAreNeverGhosts() {
    let finished = issue(key: "DEMO-5", status: "Done",
                         due: now.addingTimeInterval(-days(10)),
                         updated: now)
    #expect(calc.evaluate([finished], now: now).ghostCount == 0)
}

@Test func scoreNeverGoesBelowZero() {
    let report = calc.evaluate(activeIssues(60), now: now)
    #expect(report.score == 0)
}

@Test func nextStepPointsAtTheBiggestPenalty() {
    let report = calc.evaluate(activeIssues(12), now: now)
    #expect(report.nextStep == .reduceWIP(to: 5, gain: 56))
}

@Test func unmappedStatusesAreIgnoredNotMiscounted() {
    let unknown = issue(key: "DEMO-6", status: "검토 대기", updated: now.addingTimeInterval(-days(30)))
    let report = calc.evaluate([unknown], now: now)
    #expect(report.score == 100)
}
