import Foundation

/// 직전 미러와 새 조회 결과를 비교해 관측 이벤트를 만든다.
/// 출력은 항상 issueKey 오름차순이라 같은 입력이면 같은 결과가 나온다.
public struct DiffEngine: Sendable {
    public init() {}

    public func diff(
        previous: [String: ObservedIssue],
        current: [ObservedIssue],
        observedAt: Date
    ) -> [DomainEvent] {
        var events: [DomainEvent] = []
        let currentByKey = Dictionary(uniqueKeysWithValues: current.map { ($0.key, $0) })

        for key in currentByKey.keys.sorted() {
            let now = currentByKey[key]!
            guard let before = previous[key] else {
                events.append(DomainEvent(
                    issueKey: key, kind: .appeared, fromStatus: nil, toStatus: now.statusName,
                    observedAt: observedAt, actorAccountId: now.assigneeAccountId,
                    priorUpdatedAt: nil,   // 직전 값이 없다. 근사조차 불가능하므로 nil이 정직하다.
                    dueDateAtObservation: now.dueDate
                ))
                continue
            }

            // 직전 미러의 jiraUpdatedAt이 이 변화의 정체 기준선이다. 미러는 곧 덮이므로
            // 지금 이벤트에 실어두지 않으면 나중에 어떤 규칙으로도 복원할 수 없다.
            let baseline = before.jiraUpdatedAt
            // 마감일도 같은 이유로 싣는다. 티켓이 조회 결과에서 사라지면 미러에서도 사라진다.
            let dueDate = now.dueDate

            if before.statusName != now.statusName {
                events.append(DomainEvent(
                    issueKey: key, kind: .statusChanged,
                    fromStatus: before.statusName, toStatus: now.statusName,
                    observedAt: observedAt, actorAccountId: now.assigneeAccountId,
                    priorUpdatedAt: baseline, dueDateAtObservation: dueDate
                ))
            } else if before.jiraUpdatedAt != now.jiraUpdatedAt {
                events.append(DomainEvent(
                    issueKey: key, kind: .touched, fromStatus: nil, toStatus: nil,
                    observedAt: observedAt, actorAccountId: now.assigneeAccountId,
                    priorUpdatedAt: baseline, dueDateAtObservation: dueDate
                ))
            }

            if before.dueDate != now.dueDate {
                events.append(DomainEvent(
                    issueKey: key, kind: .dueDateChanged, fromStatus: nil, toStatus: nil,
                    observedAt: observedAt, actorAccountId: now.assigneeAccountId,
                    priorUpdatedAt: baseline, dueDateAtObservation: dueDate
                ))
            }
        }

        for key in previous.keys.sorted() where currentByKey[key] == nil {
            let before = previous[key]!
            events.append(DomainEvent(
                issueKey: key, kind: .vanished, fromStatus: before.statusName, toStatus: nil,
                observedAt: observedAt, actorAccountId: before.assigneeAccountId,
                priorUpdatedAt: before.jiraUpdatedAt, dueDateAtObservation: before.dueDate
            ))
        }

        return events
    }
}
