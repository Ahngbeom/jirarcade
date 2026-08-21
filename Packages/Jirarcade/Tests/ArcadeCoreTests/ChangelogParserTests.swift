import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

private func history(
    id: String, at: Date, author: String?, items: [JiraChangelogItem]
) -> JiraChangelogHistory {
    JiraChangelogHistory(id: id, createdAt: at, authorAccountId: author, items: items)
}

private func statusItem(fromId: String, from: String, toId: String, to: String) -> JiraChangelogItem {
    JiraChangelogItem(field: "status", fromId: fromId, fromString: from,
                      toId: toId, toString: to)
}

private func issue(
    key: String = "MPT-1",
    created: Date = iso("2023-01-01T00:00:00Z"),
    due: Date? = nil,
    histories: [JiraChangelogHistory]
) -> JiraIssueWithChangelog {
    JiraIssueWithChangelog(
        key: key, createdAt: created, dueDate: due,
        changelog: JiraChangelogPage(startAt: 0, maxResults: 100,
                                     total: histories.count, histories: histories)
    )
}

/// status 항목만 이벤트가 된다. description·Link·Fix Version은 버린다(스펙 §4.1).
@Test func onlyStatusItemsBecomeEvents() throws {
    let parsed = ChangelogParser().parse(issue: issue(histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me", items: [
            JiraChangelogItem(field: "description", fromId: nil, fromString: "old",
                              toId: nil, toString: "new"),
            statusItem(fromId: "1", from: "To Do", toId: "2", to: "In Progress"),
            JiraChangelogItem(field: "Link", fromId: nil, fromString: nil,
                              toId: nil, toString: "blocks MPT-2"),
        ])
    ]))
    #expect(parsed.count == 1)
    // #expect는 실패해도 멈추지 않는다. 위 count가 어긋난 채 parsed[0]을 쓰면
    // 테스트 실패가 아니라 인덱스 범위 초과로 프로세스가 죽는다 — try #require로 꺼낸다.
    let only = try #require(parsed.first)
    #expect(only.event.kind == .statusChanged)
    #expect(only.event.issueKey == "MPT-1")
    #expect(only.event.fromStatus == "To Do")
    #expect(only.event.toStatus == "In Progress")
}

/// issueKey는 이벤트를 티켓에 붙이는 **유일한** 키다. 틀리면 XP가 엉뚱한 티켓에 붙는다.
/// 티켓을 두 개 돌려 상수가 아니라 입력에서 온 값임을 고정한다 — 한 티켓만 보면
/// 하드코딩된 키도 통과해 버린다.
@Test func eventsCarryTheirOwnIssueKey() throws {
    let parser = ChangelogParser()
    let twoHistories = [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")]),
        history(id: "2", at: iso("2023-02-10T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "2", from: "B", toId: "3", to: "C")]),
    ]
    let first = parser.parse(issue: issue(key: "MPT-1", histories: twoHistories))
    let second = parser.parse(issue: issue(key: "MPT-42", histories: twoHistories))

    #expect(first.count == 2)
    #expect(second.count == 2)
    #expect(first.allSatisfy { $0.event.issueKey == "MPT-1" })
    #expect(second.allSatisfy { $0.event.issueKey == "MPT-42" })
}

/// observedAt은 전이 시각이지 백필 실행 시각이 아니다. 틀리면 3년치가 오늘로 몰린다.
@Test func observedAtIsTheTransitionTime() throws {
    let when = iso("2023-02-28T10:15:06Z")
    let parsed = ChangelogParser().parse(issue: issue(histories: [
        history(id: "1", at: when, author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")])
    ]))
    #expect(try #require(parsed.first).event.observedAt == when)
}

@Test func historyIdAndStatusIdsAreCarried() throws {
    let parsed = ChangelogParser().parse(issue: issue(histories: [
        history(id: "50347", at: iso("2023-02-28T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "10009", from: "To Do", toId: "10016", to: "In Progress")])
    ]))
    let only = try #require(parsed.first)
    #expect(only.historyId == "50347")
    #expect(only.fromStatusId == "10009")
    #expect(only.toStatusId == "10016")
}

/// 백필의 actorAccountId는 changelog가 알려준 **실제 행위자**다. 라이브 동기화가 쓰는
/// assignee 근사값과 다르다 — "내가 직접 옮긴 것만 XP"를 판정하려면 이 값이어야 한다.
@Test func actorComesFromTheHistoryAuthor() throws {
    let parsed = ChangelogParser().parse(issue: issue(histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-someone",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")])
    ]))
    #expect(try #require(parsed.first).event.actorAccountId == "acc-someone")
}

/// 행위자를 모르는 history도 있다(자동화·삭제된 계정). nil이면 nil로 남긴다 —
/// 내 계정으로 추측하면 남의 전이가 내 XP가 된다.
@Test func missingAuthorStaysNil() throws {
    let parsed = ChangelogParser().parse(issue: issue(histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: nil,
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")])
    ]))
    #expect(try #require(parsed.first).event.actorAccountId == nil)
}

/// priorUpdatedAt은 **직전 history의 created**다. 티켓의 모든 변경이 changelog에 남으므로
/// 어떤 전이 직전의 마지막 수정 시각은 곧 그 앞 history의 시각이다(스펙 §4.3).
@Test func priorUpdatedAtComesFromThePrecedingHistory() throws {
    let first = iso("2023-02-01T00:00:00Z")
    let second = iso("2023-02-10T00:00:00Z")
    let parsed = ChangelogParser().parse(issue: issue(created: iso("2023-01-01T00:00:00Z"), histories: [
        history(id: "1", at: first, author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")]),
        history(id: "2", at: second, author: "acc-me",
                items: [statusItem(fromId: "2", from: "B", toId: "3", to: "C")]),
    ]))
    #expect(parsed.count == 2)
    #expect(try #require(parsed.dropFirst().first).event.priorUpdatedAt == first)
}

/// 첫 history 앞에는 변경이 없으므로 티켓 생성 시각을 쓴다.
@Test func firstHistoryUsesIssueCreationAsPrior() throws {
    let created = iso("2023-01-01T00:00:00Z")
    let parsed = ChangelogParser().parse(issue: issue(created: created, histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")])
    ]))
    #expect(try #require(parsed.first).event.priorUpdatedAt == created)
}

/// status가 아닌 history도 priorUpdatedAt 계산에는 참여한다 — 그 시점에 티켓이 수정됐으므로.
@Test func nonStatusHistoriesStillAdvanceThePriorTimestamp() throws {
    let edit = iso("2023-02-05T00:00:00Z")
    let parsed = ChangelogParser().parse(issue: issue(created: iso("2023-01-01T00:00:00Z"), histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")]),
        history(id: "2", at: edit, author: "acc-me", items: [
            JiraChangelogItem(field: "description", fromId: nil, fromString: "old",
                              toId: nil, toString: "new")
        ]),
        history(id: "3", at: iso("2023-02-20T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "2", from: "B", toId: "3", to: "C")]),
    ]))
    #expect(parsed.count == 2)
    #expect(try #require(parsed.dropFirst().first).event.priorUpdatedAt == edit,
            "description 수정도 티켓을 갱신한다")
}

/// 한 history 안에 status가 여러 개 있으면 모두 같은 priorUpdatedAt을 갖는다 —
/// 하나의 저장 묶음이므로 그 사이에 "직전 수정"이 끼어들 수 없다.
@Test func twoStatusItemsInOneHistoryShareThePrior() throws {
    let created = iso("2023-01-01T00:00:00Z")
    let at = iso("2023-02-01T00:00:00Z")
    let parsed = ChangelogParser().parse(issue: issue(created: created, histories: [
        history(id: "1", at: at, author: "acc-me", items: [
            statusItem(fromId: "1", from: "A", toId: "2", to: "B"),
            statusItem(fromId: "2", from: "B", toId: "3", to: "C"),
        ])
    ]))
    #expect(parsed.count == 2)
    #expect(parsed.allSatisfy { $0.event.priorUpdatedAt == created })
    #expect(parsed.allSatisfy { $0.historyId == "1" })
}

/// 마감일 변경 이력이 있으면 그 시점의 값을 쓴다(스펙 §4.3).
@Test func dueDateAtObservationTracksDuedateChanges() throws {
    let parsed = ChangelogParser().parse(issue: issue(
        created: iso("2023-01-01T00:00:00Z"),
        due: iso("2023-04-01T00:00:00Z"),      // 현재 값
        histories: [
            history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                    items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")]),
            history(id: "2", at: iso("2023-03-01T00:00:00Z"), author: "acc-me", items: [
                JiraChangelogItem(field: "duedate", fromId: nil, fromString: "2023-02-15",
                                  toId: nil, toString: "2023-04-01")
            ]),
        ]
    ))
    // 첫 전이 시점의 마감일은 변경 **이전** 값이어야 한다.
    #expect(try #require(parsed.first).event.dueDateAtObservation == iso("2023-02-15T00:00:00Z"))
}

/// status와 duedate가 **같은 저장 묶음**에서 바뀌면 그 전이에는 새 마감일을 적용한다.
/// 동시에 일어난 변경이므로 "그때의 마감일"은 바꾼 결과값으로 본다.
///
/// 기대값(2023-04-01)은 세 값과 모두 다르게 잡아 두었다 — 바꾸기 **전** 값(2023-02-15)도,
/// 티켓의 **현재** 값(2023-06-01)도 아니다. 셋이 겹치면 "새 값을 썼다"와 "시간축을 무시하고
/// 현재 값으로 폴백했다"를 구분하지 못한다.
@Test func simultaneousDueDateChangeUsesTheNewValue() throws {
    let parsed = ChangelogParser().parse(issue: issue(
        created: iso("2023-01-01T00:00:00Z"),
        due: iso("2023-06-01T00:00:00Z"),      // 현재 값 — 그때의 값과 달라야 한다
        histories: [
            history(id: "1", at: iso("2023-03-01T00:00:00Z"), author: "acc-me", items: [
                statusItem(fromId: "1", from: "A", toId: "2", to: "B"),
                JiraChangelogItem(field: "duedate", fromId: nil, fromString: "2023-02-15",
                                  toId: nil, toString: "2023-04-01"),
            ]),
            // 나중에 한 번 더 옮겨서 현재 값과 전이 시점 값을 갈라놓는다.
            history(id: "2", at: iso("2023-05-01T00:00:00Z"), author: "acc-me", items: [
                JiraChangelogItem(field: "duedate", fromId: nil, fromString: "2023-04-01",
                                  toId: nil, toString: "2023-06-01")
            ]),
        ]
    ))
    #expect(parsed.count == 1)
    #expect(try #require(parsed.first).event.dueDateAtObservation == iso("2023-04-01T00:00:00Z"))
}

/// 마감일 변경 이력이 없으면 현재 값이 그때도 같았다는 뜻이다.
@Test func dueDateFallsBackToTheCurrentValue() throws {
    let due = iso("2023-04-01T00:00:00Z")
    let parsed = ChangelogParser().parse(issue: issue(due: due, histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")])
    ]))
    #expect(try #require(parsed.first).event.dueDateAtObservation == due)
}

/// history가 시간 역순으로 와도 결과는 시간순이어야 한다 — Jira는 최신순으로 준다.
@Test func historiesAreSortedChronologically() {
    let early = iso("2023-02-01T00:00:00Z")
    let late = iso("2023-03-01T00:00:00Z")
    let parsed = ChangelogParser().parse(issue: issue(histories: [
        history(id: "2", at: late, author: "acc-me",
                items: [statusItem(fromId: "2", from: "B", toId: "3", to: "C")]),
        history(id: "1", at: early, author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")]),
    ]))
    #expect(parsed.map(\.event.observedAt) == [early, late])
}

@Test func emptyChangelogProducesNothing() {
    #expect(ChangelogParser().parse(issue: issue(histories: [])).isEmpty)
}
