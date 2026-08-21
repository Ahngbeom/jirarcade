import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

private var utc: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private func engine() -> ScoreEngine {
    ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc, myAccountId: "acc-me")
}

private func statusItem(from: (String, String), to: (String, String)) -> JiraChangelogItem {
    JiraChangelogItem(field: "status", fromId: from.1, fromString: from.0,
                      toId: to.1, toString: to.0)
}

/// 내가 혼자 To Do → In Progress → In Review → Done까지 옮긴 티켓 하나의 changelog.
/// 마지막 전이가 Done이어야 마감 보너스가 걸리고, 그래야 "채점이 미러의 마감일을 보는가"를
/// 구별할 수 있다 — Done이 아닌 changelog로는 그 오염을 아예 관측할 수 없다.
private func backfilledEvents() -> [DomainEvent] {
    let issue = JiraIssueWithChangelog(
        key: "MPT-1", createdAt: iso("2023-01-01T00:00:00Z"),
        dueDate: iso("2023-03-01T00:00:00Z"),
        changelog: JiraChangelogPage(startAt: 0, maxResults: 100, total: 3, histories: [
            JiraChangelogHistory(id: "1", createdAt: iso("2023-02-01T00:00:00Z"),
                                 authorAccountId: "acc-me",
                                 items: [statusItem(from: ("To Do", "1"),
                                                    to: ("In Progress", "2"))]),
            JiraChangelogHistory(id: "2", createdAt: iso("2023-02-20T00:00:00Z"),
                                 authorAccountId: "acc-me",
                                 items: [statusItem(from: ("In Progress", "2"),
                                                    to: ("In Review", "3"))]),
            JiraChangelogHistory(id: "3", createdAt: iso("2023-02-25T00:00:00Z"),
                                 authorAccountId: "acc-me",
                                 items: [statusItem(from: ("In Review", "3"),
                                                    to: ("Done", "4"))]),
        ])
    )
    return ChangelogParser().parse(issue: issue).map(\.event)
}

/// 계획 1 최종 리뷰에서 확립된 불변식: **이벤트 채점**은 (이벤트 로그, RuleSet)만의 함수다.
/// 백필 이벤트도 이를 지켜야 한다 — 미러를 비워도 이벤트별 XP가 같아야 한다(스펙 §4.3).
///
/// 미러는 **현재 상태만** 담고 재집계 직전에 최신값으로 덮인다. 채점이 미러를 들여다보면
/// 어제 준 XP가 오늘 조회 결과에 따라 달라진다 — 티켓이 조회 범위에서 빠지는 것만으로
/// 과거 점수가 증발한다. 그래서 마감일과 정체 기준선을 이벤트가 직접 들고 다닌다.
///
/// 위생 데일리 보너스(`hygieneBonusXP`)는 이 불변식의 예외다. 스펙 §5.3이 그것을
/// **오늘의 미러**로 판정하도록 정했으므로 미러가 없으면 0이 되는 것이 정상이다.
/// `PlayerSummary`가 그 값을 따로 노출하는 이유가 여기 있다 — 빼고 비교할 수 있어야 한다.
@Test func backfillScoresDoNotDependOnTheMirror() {
    let engine = engine()
    let events = backfilledEvents()
    let now = iso("2026-08-13T00:00:00Z")

    let withMirror = engine.recompute(
        events: events,
        issues: ["MPT-1": ObservedIssue(
            key: "MPT-1", summary: "s", statusName: "Done", issueType: "개선",
            priority: nil, assigneeAccountId: "acc-me", assigneeName: nil,
            dueDate: iso("2099-01-01T00:00:00Z"),   // 미러의 마감일을 극단적으로 바꾼다
            jiraUpdatedAt: now                       // 미러의 갱신 시각도 오늘로 덮는다
        )],
        now: now
    )
    let withoutMirror = engine.recompute(events: events, issues: [:], now: now)

    #expect(withoutMirror.scored.contains { $0.xp > 0 }, "0끼리 비교하면 아무것도 검증하지 못한다")
    #expect(withMirror.scored.map(\.xp) == withoutMirror.scored.map(\.xp),
            "미러가 이벤트 XP를 바꾸면 재집계가 미러 상태에 오염된다")

    // 이벤트에서 온 XP만 비교한다. 위생 보너스는 설계상 미러에서 오므로 빼고 본다.
    #expect(withMirror.summary.totalXP - withMirror.summary.hygieneBonusXP
            == withoutMirror.summary.totalXP - withoutMirror.summary.hygieneBonusXP)
    #expect(withoutMirror.summary.hygieneBonusXP == 0,
            "미러가 비면 위생을 판정할 대상이 없다 — 감점 대상이 없다고 만점을 주면 안 된다")
}

/// 백필 이벤트의 재집계도 멱등이다. 재집계는 누적 갱신이 아니라 항상 처음부터 계산하므로
/// 같은 입력에 같은 결과가 나와야 한다 — 여기서 갈리면 재집계 안에 상태가 새어 든 것이다.
@Test func backfillRecomputeIsIdempotent() {
    let engine = engine()
    let now = iso("2026-08-13T00:00:00Z")
    let first = engine.recompute(events: backfilledEvents(), issues: [:], now: now)
    let second = engine.recompute(events: backfilledEvents(), issues: [:], now: now)

    #expect(first.summary.totalXP > 0, "0끼리 비교하면 아무것도 검증하지 못한다")
    #expect(first.summary == second.summary)
    #expect(first.scored == second.scored)
}

/// 시즌은 **범위만** 자르고 채점 규칙은 바꾸지 않는다. 같은 이벤트는 통산과 시즌에서
/// 같은 XP를 받아야 한다 — 사용자가 HUD의 시즌 레벨과 프로필의 통산 레벨을 나란히 보므로
/// 어긋나면 즉시 드러난다.
///
/// 이 불변식은 `statusEnteredAt` 재구성이 두 호출에서 공유되기 때문에 성립한다. 시즌 필터를
/// 정렬 직후에 적용하도록 바꾸면 시즌 안 첫 전이의 정체 기준선이 사라져 조용히 깨진다.
/// 그래서 두 이벤트를 **같은 티켓**에 둔다 — 티켓이 다르면 기준선을 공유할 일이 없어
/// 이 테스트가 아무것도 지키지 못한다.
@Test func sameEventScoresIdenticallyInSeasonAndLifetime() throws {
    let engine = engine()
    let now = iso("2026-08-20T00:00:00Z")
    let events = [
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged,
                    fromStatus: "To Do", toStatus: "In Progress",
                    observedAt: iso("2026-02-01T00:00:00Z"), actorAccountId: "acc-me",
                    priorUpdatedAt: iso("2026-01-11T00:00:00Z")),
        // 시즌 안의 전이. 통산에서는 위 전이가 정체 기준선(6개월 전)을 만들어 준다.
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged,
                    fromStatus: "In Progress", toStatus: "In Review",
                    observedAt: iso("2026-08-15T00:00:00Z"), actorAccountId: "acc-me",
                    priorUpdatedAt: iso("2026-08-14T00:00:00Z")),
    ]

    let lifetime = engine.recompute(events: events, issues: [:], now: now)
    let season = engine.recompute(events: events, issues: [:], now: now,
                                  since: iso("2026-07-21T00:00:00Z"))

    #expect(season.scored.count == 1, "시즌은 범위 밖 이벤트를 집계에서 빼야 한다")
    let inSeason = try #require(season.scored.first).xp
    let inLifetime = try #require(
        lifetime.scored.first { $0.event.observedAt == iso("2026-08-15T00:00:00Z") }
    ).xp

    #expect(inSeason > 0, "0끼리 비교하면 아무것도 검증하지 못한다")
    #expect(inLifetime == inSeason,
            "시즌은 범위를 자를 뿐이다 — 같은 이벤트의 XP가 달라지면 statusEnteredAt이 공유되지 않은 것이다")
}

/// 남이 옮긴 전이는 0점이지만 **버리지는 않는다**. 버리면 다음 전이의 정체 기준선이
/// 그만큼 과거로 밀려 정체일이 부풀고, 정체 깨우기 XP가 과다 지급된다(스펙 §4.2).
///
/// "기준선이 전진한다"를 상수로 확인하면 RuleSet이 바뀔 때 의미가 흔들린다. 남의 전이를
/// 아예 못 본 changelog로 한 번 더 채점해 직접 비교한다 — 그 차이가 곧 이 불변식의 내용이다.
@Test func othersTransitionsAreRecordedSoStagnationIsNotInflated() throws {
    let mine = JiraChangelogHistory(
        id: "2", createdAt: iso("2023-02-08T00:00:00Z"), authorAccountId: "acc-me",
        items: [statusItem(from: ("In Progress", "2"), to: ("In Review", "3"))]
    )
    let others = JiraChangelogHistory(
        id: "1", createdAt: iso("2023-02-01T00:00:00Z"), authorAccountId: "acc-other",
        items: [statusItem(from: ("To Do", "1"), to: ("In Progress", "2"))]
    )
    func parse(_ histories: [JiraChangelogHistory]) -> [DomainEvent] {
        ChangelogParser().parse(issue: JiraIssueWithChangelog(
            key: "MPT-1", createdAt: iso("2023-01-01T00:00:00Z"), dueDate: nil,
            changelog: JiraChangelogPage(startAt: 0, maxResults: 100,
                                         total: histories.count, histories: histories)
        )).map(\.event)
    }

    let engine = engine()
    let now = iso("2026-08-13T00:00:00Z")
    let recorded = engine.recompute(events: parse([others, mine]), issues: [:], now: now)

    #expect(recorded.scored.count == 2, "남의 전이도 로그에는 남는다")
    let othersScored = try #require(recorded.scored.first)
    let mineScored = try #require(recorded.scored.dropFirst().first)
    #expect(othersScored.event.actorAccountId == "acc-other")
    #expect(othersScored.xp == 0, "남이 옮긴 전이는 기록하되 점수를 주지 않는다")
    #expect(mineScored.xp > 0)

    // 남의 전이를 파싱 단계에서 버렸다면 내 전이의 기준선은 티켓 생성 시각(2023-01-01)까지
    // 밀린다. 7일 정체가 38일 정체로 둔갑하므로 XP가 커진다.
    let dropped = engine.recompute(events: parse([mine]), issues: [:], now: now)
    let inflated = try #require(dropped.scored.first).xp
    #expect(inflated > mineScored.xp,
            "남의 전이를 버리면 정체가 부풀어 XP가 커진다 — 그래서 기록은 남겨야 한다")
}

/// 0점 이벤트도 `statusEnteredAt`을 전진시킨다. 채점기가 "점수 없는 이벤트는 무시"로
/// 바뀌면 기준선이 `priorUpdatedAt` 폴백으로 내려앉아 채점이 달라진다.
///
/// 두 값이 갈리도록 남의 전이와 내 전이 사이에 **상태가 아닌 변경**을 하나 끼운다.
/// 그러면 `priorUpdatedAt`은 그 변경 시각(2023-02-05)이고 `statusEnteredAt`은 남의 전이
/// 시각(2023-02-01)이라, 어느 쪽이 쓰였는지 XP로 구별된다.
@Test func othersTransitionsAdvanceTheStagnationBaseline() throws {
    let events = ChangelogParser().parse(issue: JiraIssueWithChangelog(
        key: "MPT-1", createdAt: iso("2023-01-01T00:00:00Z"), dueDate: nil,
        changelog: JiraChangelogPage(startAt: 0, maxResults: 100, total: 3, histories: [
            JiraChangelogHistory(id: "1", createdAt: iso("2023-02-01T00:00:00Z"),
                                 authorAccountId: "acc-other",
                                 items: [statusItem(from: ("To Do", "1"),
                                                    to: ("In Progress", "2"))]),
            JiraChangelogHistory(id: "2", createdAt: iso("2023-02-05T00:00:00Z"),
                                 authorAccountId: "acc-me",
                                 items: [JiraChangelogItem(field: "description", fromId: nil,
                                                           fromString: "before", toId: nil,
                                                           toString: "after")]),
            JiraChangelogHistory(id: "3", createdAt: iso("2023-02-08T00:00:00Z"),
                                 authorAccountId: "acc-me",
                                 items: [statusItem(from: ("In Progress", "2"),
                                                    to: ("In Review", "3"))]),
        ])
    )).map(\.event)

    let engine = engine()
    let now = iso("2026-08-13T00:00:00Z")
    let withBaseline = engine.recompute(events: events, issues: [:], now: now)
    let mine = try #require(withBaseline.scored.first { $0.event.actorAccountId == "acc-me" }).xp
    #expect(mine > 0, "0끼리 비교하면 아무것도 검증하지 못한다")

    // 0점 이벤트를 기준선 재구성에서 빼면 남는 것은 priorUpdatedAt 폴백뿐이다.
    let withoutBaseline = engine.recompute(
        events: events.filter { $0.actorAccountId == "acc-me" }, issues: [:], now: now
    )
    let fallback = try #require(withoutBaseline.scored.first).xp
    #expect(fallback != mine,
            "남의 전이를 기준선에서 빼면 정체 계산이 달라진다 — 같다면 이 테스트가 아무것도 지키지 않는다")
}

/// 백필을 두 번 돌려도 XP가 두 배가 되지 않는다. 이 계획의 핵심 약속이고,
/// historyId 중복 검사가 그것을 지킨다. 이벤트 수만 보는 검사(Task 11)와 달리
/// **점수 층위에서** 고정한다 — 사용자가 실제로 보는 값이 그쪽이기 때문이다.
@MainActor
@Test func runningBackfillTwiceDoesNotDoubleXP() throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let engine = engine()
    let now = iso("2026-08-13T00:00:00Z")
    let events = backfilledEvents()
    let historyIds = events.enumerated().map { "h-\($0.offset)" }

    let firstInsert = try store.appendBackfillEvents(events, historyIds: historyIds)
    #expect(firstInsert == events.count)
    let after1 = engine.recompute(events: try store.loadEvents(), issues: [:], now: now)

    let secondInsert = try store.appendBackfillEvents(events, historyIds: historyIds)
    #expect(secondInsert == 0, "같은 historyId는 두 번 들어가지 않는다")
    let after2 = engine.recompute(events: try store.loadEvents(), issues: [:], now: now)

    #expect(after1.summary.totalXP > 0, "0끼리 비교하면 아무것도 검증하지 못한다")
    #expect(after1.summary.totalXP == after2.summary.totalXP)
    #expect(after1.summary.level == after2.summary.level)
}
