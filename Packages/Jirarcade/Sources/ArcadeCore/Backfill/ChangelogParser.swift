import Foundation
import JiraKit

/// changelog에서 뽑아낸 상태 전이 하나. 이벤트와 함께 중복 판정용 id와
/// 폴백 조회용 상태 ID를 들고 다닌다.
public struct ParsedTransition: Sendable, Equatable {
    public let event: DomainEvent
    public let historyId: String
    public let fromStatusId: String?
    public let toStatusId: String?
}

/// changelog를 `DomainEvent`로 번역하는 순수 함수.
///
/// 네트워크도 저장소도 모른다 — 입력은 이미 받아온 티켓 하나, 출력은 전이 배열이다.
/// 그래서 밀리초 단위로 테스트된다.
public struct ChangelogParser: Sendable {
    public init() {}

    public func parse(issue: JiraIssueWithChangelog) -> [ParsedTransition] {
        // Jira는 최신순으로 주기도 한다. priorUpdatedAt이 "직전 history"에 의존하므로
        // 시간순으로 세우는 것이 전제 조건이다.
        let ordered = issue.changelog.histories.sorted { $0.createdAt < $1.createdAt }

        // 마감일의 시간축을 먼저 만든다. duedate 변경 이력을 시간순으로 훑으면
        // 각 시점의 값을 알 수 있고, 이력이 없으면 현재 값이 내내 같았다는 뜻이다.
        let dueTimeline = dueDateTimeline(ordered: ordered, current: issue.dueDate)

        var result: [ParsedTransition] = []
        // 직전 수정 시각. 첫 history 앞에는 변경이 없으므로 티켓 생성 시각에서 시작한다.
        var priorUpdatedAt = issue.createdAt

        for entry in ordered {
            for item in entry.items where item.field == "status" {
                result.append(ParsedTransition(
                    event: DomainEvent(
                        issueKey: issue.key,
                        kind: .statusChanged,
                        fromStatus: item.fromString,
                        toStatus: item.toString,
                        observedAt: entry.createdAt,
                        actorAccountId: entry.authorAccountId,
                        priorUpdatedAt: priorUpdatedAt,
                        dueDateAtObservation: dueTimeline.value(at: entry.createdAt)
                    ),
                    historyId: entry.id,
                    fromStatusId: item.fromId,
                    toStatusId: item.toId
                ))
            }
            // status가 아닌 변경도 티켓을 갱신한다 — 다음 전이의 기준선이 된다.
            priorUpdatedAt = entry.createdAt
        }
        return result
    }

    // MARK: - 마감일 시간축

    private struct DueTimeline {
        /// (변경 시각, 그 시각 **이전**까지 유효했던 값)
        let changes: [(at: Date, previous: Date?)]
        let current: Date?

        func value(at when: Date) -> Date? {
            // `when`보다 **나중에** 일어난 첫 변경을 찾으면, 그 변경의 previous가
            // 그 시점에 유효했던 값이다. 그런 변경이 없으면 이후로 바뀐 적이 없다는
            // 뜻이므로 현재 값을 쓴다.
            //
            // 등호는 일부러 포함하지 않는다(`<`이지 `<=`가 아니다) — status와 duedate가
            // 같은 저장 묶음에서 바뀌면 동시에 일어난 변경이므로 그 전이에는 바뀐
            // 결과값을 적용한다.
            changes.first { when < $0.at }?.previous ?? current
        }
    }

    private func dueDateTimeline(
        ordered: [JiraChangelogHistory], current: Date?
    ) -> DueTimeline {
        var changes: [(at: Date, previous: Date?)] = []
        for entry in ordered {
            for item in entry.items where item.field == "duedate" {
                changes.append((at: entry.createdAt,
                                previous: item.fromString.flatMap(Self.dateOnly)))
            }
        }
        return DueTimeline(changes: changes, current: current)
    }

    /// DateFormatter 생성은 비싸다. 백필은 티켓 1,000여 개를 훑으므로 한 번만 만든다.
    private static let dueDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dateOnly(_ raw: String) -> Date? {
        dueDateFormatter.date(from: raw)
    }
}
