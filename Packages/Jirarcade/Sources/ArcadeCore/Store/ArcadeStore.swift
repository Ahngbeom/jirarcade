import Foundation
import SwiftData

/// 동기화 이력 한 건. @Model을 밖으로 내보내지 않기 위한 값 타입 사본.
public struct SyncRunSummary: Sendable, Equatable {
    public let startedAt: Date
    public let finishedAt: Date?
    public let observedIssueCount: Int
    /// nil이면 성공. 실패했을 때만 채워진다.
    public let failureMessage: String?
    /// 성공했지만 짚어둘 것이 있을 때의 메모(예: 페치 결과 0건).
    public let note: String?
}

public enum ArcadeStoreError: Error, Equatable {
    /// `beginSyncRun`이 돌려준 식별자로 레코드를 되찾지 못했다.
    /// 정상 흐름에서는 발생하지 않지만, 조용히 넘기면 동기화 이력이 영구히 미완료로 남는다.
    case syncRunNotFound
}

/// SwiftData 모델과 순수 값 타입 사이의 유일한 경계.
/// 규칙 엔진은 이 타입 너머의 @Model을 절대 보지 않는다.
@MainActor
public final class ArcadeStore {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    public init(container: ModelContainer) {
        self.container = container
    }

    public static func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: IssueSnapshot.self, IssueEventRecord.self, SyncRunRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    public static func makePersistentContainer() throws -> ModelContainer {
        try ModelContainer(for: IssueSnapshot.self, IssueEventRecord.self, SyncRunRecord.self)
    }

    // MARK: - 미러

    public func loadMirror() throws -> [String: ObservedIssue] {
        let rows = try context.fetch(FetchDescriptor<IssueSnapshot>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.asObservedIssue) })
    }

    /// 미러를 새 조회 결과로 맞추고 이벤트를 덧붙인다.
    ///
    /// - Parameter issues: `nil`이면 미러를 건드리지 않는다(이벤트만 기록하는 호출).
    ///   `[]`는 "전부 사라졌다"는 뜻이라 미러를 비운다.
    ///   빈 배열을 "미러 미변경"으로 쓰면 `vanished` 이벤트가 매 동기화마다 재생성된다 —
    ///   미러가 지워지지 않으니 다음 diff가 같은 이벤트를 또 만들기 때문이다.
    public func applySync(issues: [ObservedIssue]?, events: [DomainEvent], observedAt: Date) throws {
        if let issues {
            let existing = try context.fetch(FetchDescriptor<IssueSnapshot>())
            var byKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })

            for issue in issues {
                if let row = byKey.removeValue(forKey: issue.key) {
                    row.apply(issue, observedAt: observedAt)
                } else {
                    context.insert(IssueSnapshot(issue, observedAt: observedAt))
                }
            }
            for orphan in byKey.values {
                context.delete(orphan)   // 미러만 정리한다. 이벤트 로그는 그대로 둔다.
            }
        }

        for event in events {
            context.insert(IssueEventRecord(
                issueKey: event.issueKey, kindRaw: event.kind.rawValue,
                fromStatus: event.fromStatus, toStatus: event.toStatus,
                observedAt: event.observedAt, actorAccountId: event.actorAccountId,
                priorUpdatedAt: event.priorUpdatedAt,
                dueDateAtObservation: event.dueDateAtObservation
            ))
        }

        try context.save()
    }

    // MARK: - 이벤트

    public func loadEvents() throws -> [DomainEvent] {
        let descriptor = FetchDescriptor<IssueEventRecord>(
            sortBy: [SortDescriptor(\.observedAt, order: .forward)]
        )
        return try context.fetch(descriptor).compactMap { record in
            guard let kind = EventKind(rawValue: record.kindRaw) else { return nil }
            return DomainEvent(
                issueKey: record.issueKey, kind: kind,
                fromStatus: record.fromStatus, toStatus: record.toStatus,
                observedAt: record.observedAt, actorAccountId: record.actorAccountId,
                priorUpdatedAt: record.priorUpdatedAt,
                dueDateAtObservation: record.dueDateAtObservation
            )
        }
    }

    // MARK: - 동기화 이력

    public func beginSyncRun(at start: Date) throws -> PersistentIdentifier {
        let record = SyncRunRecord(startedAt: start)
        context.insert(record)
        try context.save()
        return record.persistentModelID
    }

    /// - Parameters:
    ///   - failure: 동기화가 **실패했을 때만** 채운다. 성공에 문구를 넣으면 그 동기화가
    ///     `observationDayCount`에서 배제된다.
    ///   - note: 성공했지만 짚어둘 것이 있을 때(예: 페치 결과 0건).
    public func finishSyncRun(
        _ id: PersistentIdentifier, at end: Date, issueCount: Int,
        failure: String?, note: String? = nil
    ) throws {
        // 조용히 return하면 이 SyncRunRecord가 finishedAt == nil로 영원히 남고,
        // observationDayCount의 #Predicate가 이를 영구 배제한다. 하필 가장 이른 성공
        // 동기화에서 발생하면 "관측 N일차"가 계속 0을 표시한다 — 추적이 거의 불가능한 실패다.
        guard let record = context.model(for: id) as? SyncRunRecord else {
            throw ArcadeStoreError.syncRunNotFound
        }
        record.finishedAt = end
        record.observedIssueCount = issueCount
        record.failureMessage = failure
        record.note = note
        try context.save()
    }

    /// 동기화 이력을 시작 시각 오름차순으로 돌려준다.
    /// `failureMessage`를 밖에서 읽을 수 있는 유일한 경로다(진단 화면·테스트).
    public func loadSyncRuns() throws -> [SyncRunSummary] {
        let descriptor = FetchDescriptor<SyncRunRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
        return try context.fetch(descriptor).map {
            SyncRunSummary(
                startedAt: $0.startedAt, finishedAt: $0.finishedAt,
                observedIssueCount: $0.observedIssueCount,
                failureMessage: $0.failureMessage, note: $0.note
            )
        }
    }

    /// 첫 성공 동기화 이후 며칠째인지. 성공한 동기화가 없으면 0.
    /// 달력은 반드시 주입받는다 — 다른 계산기와 다른 달력을 쓰면 "관측 N일차"가 하루 어긋난다.
    public func observationDayCount(now: Date, calendar: Calendar) throws -> Int {
        var descriptor = FetchDescriptor<SyncRunRecord>(
            predicate: #Predicate { $0.failureMessage == nil && $0.finishedAt != nil },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
        descriptor.fetchLimit = 1
        guard let first = try context.fetch(descriptor).first else { return 0 }

        let start = calendar.startOfDay(for: first.startedAt)
        let today = calendar.startOfDay(for: now)
        let elapsed = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        return max(1, elapsed + 1)
    }
}

// MARK: - 변환

private extension IssueSnapshot {
    var asObservedIssue: ObservedIssue {
        ObservedIssue(
            key: key, summary: summary, statusName: statusName, issueType: issueType,
            priority: priority, assigneeAccountId: assigneeAccountId, assigneeName: assigneeName,
            dueDate: dueDate, jiraUpdatedAt: jiraUpdatedAt
        )
    }

    convenience init(_ issue: ObservedIssue, observedAt: Date) {
        self.init(
            key: issue.key, summary: issue.summary, statusName: issue.statusName,
            issueType: issue.issueType, priority: issue.priority,
            assigneeAccountId: issue.assigneeAccountId, assigneeName: issue.assigneeName,
            dueDate: issue.dueDate, jiraUpdatedAt: issue.jiraUpdatedAt,
            firstObservedAt: observedAt, lastObservedAt: observedAt
        )
    }

    func apply(_ issue: ObservedIssue, observedAt: Date) {
        summary = issue.summary
        statusName = issue.statusName
        issueType = issue.issueType
        priority = issue.priority
        assigneeAccountId = issue.assigneeAccountId
        assigneeName = issue.assigneeName
        dueDate = issue.dueDate
        jiraUpdatedAt = issue.jiraUpdatedAt
        lastObservedAt = observedAt
    }
}
