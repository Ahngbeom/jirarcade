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
    /// `beginBackfill`이 돌려준 식별자로 레코드를 되찾지 못했다.
    /// 조용히 넘기면 진행 상황이 저장되지 않은 채 호출자는 성공으로 안다.
    case backfillRunNotFound
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
            BackfillRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    public static func makePersistentContainer() throws -> ModelContainer {
        try ModelContainer(
            for: IssueSnapshot.self, IssueEventRecord.self, SyncRunRecord.self,
            BackfillRun.self
        )
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

    /// 미러·이벤트 로그·동기화 이력을 전부 버린다.
    /// 다른 계정으로 로그인할 때만 쓴다 — append-only 원칙의 유일한 예외이며,
    /// 남의 데이터와 섞이는 것보다 버리는 편이 안전하기 때문이다.
    public func reset() throws {
        for row in try context.fetch(FetchDescriptor<IssueSnapshot>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<IssueEventRecord>()) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<SyncRunRecord>()) { context.delete(row) }
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

    /// 테스트와 진단용. 값 타입으로 변환하기 전의 레코드를 그대로 준다.
    /// 프로덕션 코드는 `loadEvents()`를 쓴다.
    public func rawEventRecords() throws -> [IssueEventRecord] {
        try context.fetch(FetchDescriptor<IssueEventRecord>(
            sortBy: [SortDescriptor(\.observedAt, order: .forward)]
        ))
    }

    /// 백필 이벤트를 append한다. 이미 같은 `historyId`로 기록된 것은 건너뛰고,
    /// 새로 넣은 개수를 돌려준다.
    ///
    /// `events`와 `historyIds`는 같은 길이여야 하며 인덱스로 짝지어진다.
    /// 중복 판정을 시각·상태명이 아니라 Jira가 준 id로 하는 이유: 같은 초에 두 전이가
    /// 일어날 수 있고, 왕복 전이(A→B, B→A)는 되돌아왔을 때 값이 겹친다.
    public func appendBackfillEvents(
        _ events: [DomainEvent], historyIds: [String]
    ) throws -> Int {
        precondition(events.count == historyIds.count,
                     "events와 historyIds는 인덱스로 짝지어진다")
        guard !events.isEmpty else { return 0 }

        let existing = try context.fetch(FetchDescriptor<IssueEventRecord>(
            predicate: #Predicate { $0.sourceHistoryId != nil }
        ))
        var seen = Set(existing.compactMap(\.sourceHistoryId))

        var inserted = 0
        for (event, historyId) in zip(events, historyIds) {
            guard seen.insert(historyId).inserted else { continue }
            context.insert(IssueEventRecord(
                issueKey: event.issueKey, kindRaw: event.kind.rawValue,
                fromStatus: event.fromStatus, toStatus: event.toStatus,
                observedAt: event.observedAt, actorAccountId: event.actorAccountId,
                priorUpdatedAt: event.priorUpdatedAt,
                dueDateAtObservation: event.dueDateAtObservation,
                sourceHistoryId: historyId, origin: EventOrigin.backfill
            ))
            inserted += 1
        }
        try context.save()
        return inserted
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

    // MARK: - 백필 이력

    /// 재개에 필요한 정보만 담은 값 타입. `@Model` 인스턴스를 밖으로 내보내지 않는다.
    public struct BackfillSnapshot: Sendable {
        public let id: PersistentIdentifier
        public let jql: String
        public let nextPageToken: String?
        public let processedIssueCount: Int
        public let totalIssueCount: Int
        public let discovered: [String]
        public let partiallyRestored: [String]
    }

    /// 식별자로 run을 되찾는다. 없으면 nil.
    ///
    /// `context.model(for:)`를 쓰지 않는다 — 다른 스토어에서 온 식별자를 주면 nil을
    /// 돌려주는 대신 클래스가 맞는 껍데기를 만들어 주고, 프로퍼티에 손대는 순간
    /// "backing data could no longer be found"로 크래시한다. 존재 여부를 물어야 하는
    /// 자리라서 fetch로 확인한다. run은 백필 한 번에 한 행이라 전량 조회해도 싸다.
    private func backfillRun(for id: PersistentIdentifier) throws -> BackfillRun? {
        try context.fetch(FetchDescriptor<BackfillRun>())
            .first { $0.persistentModelID == id }
    }

    public func beginBackfill(
        jql: String, at start: Date, totalIssueCount: Int
    ) throws -> PersistentIdentifier {
        // 새로 시작한다는 건 이전 미완료 run을 이어받지 않겠다는 뜻이다. 그대로 두면
        // resumableBackfill()이 계속 그걸 집어 "이어서 하시겠습니까"가 영원히 뜬다.
        // 버려진 진행 상태는 보존 가치가 없으므로 지운다 — 완료된 run은 이력으로 남는다.
        for abandoned in try context.fetch(
            FetchDescriptor<BackfillRun>(predicate: #Predicate { $0.finishedAt == nil })
        ) {
            context.delete(abandoned)
        }

        let run = BackfillRun(startedAt: start, jql: jql, totalIssueCount: totalIssueCount)
        context.insert(run)
        try context.save()
        return run.persistentModelID
    }

    public func advanceBackfill(
        _ id: PersistentIdentifier, nextPageToken: String?, processedIssueCount: Int,
        discovered: [String], partiallyRestored: [String]
    ) throws {
        // 조용히 return하면 진행 상황이 저장되지 않은 채 호출자는 성공으로 안다.
        // 재개할 때 nextPageToken이 없어 1,000여 건을 처음부터 다시 훑게 된다.
        // finishSyncRun이 syncRunNotFound를 던지는 것과 같은 이유다.
        guard let run = try backfillRun(for: id) else {
            throw ArcadeStoreError.backfillRunNotFound
        }
        run.nextPageToken = nextPageToken
        run.processedIssueCount = processedIssueCount
        // 정렬해서 저장한다. Set을 그대로 Array로 만들면 순서가 비결정적이라
        // 매핑 마법사의 후보 목록이 열 때마다 뒤바뀐다.
        run.discoveredUnmappedStatuses =
            Set(run.discoveredUnmappedStatuses).union(discovered).sorted()
        run.partiallyRestoredKeys =
            Set(run.partiallyRestoredKeys).union(partiallyRestored).sorted()
        try context.save()
    }

    public func finishBackfill(
        _ id: PersistentIdentifier, at end: Date, failure: String?
    ) throws {
        // 조용히 return하면 이 run이 finishedAt == nil로 영원히 남아
        // resumableBackfill()이 매번 "이어서 하시겠습니까"를 띄운다.
        guard let run = try backfillRun(for: id) else {
            throw ArcadeStoreError.backfillRunNotFound
        }
        run.finishedAt = end
        run.failureMessage = failure
        try context.save()
    }

    /// 아직 끝나지 않은 백필. 있으면 "이어서 불러오기"를 제안한다.
    public func resumableBackfill() throws -> BackfillSnapshot? {
        var descriptor = FetchDescriptor<BackfillRun>(
            predicate: #Predicate { $0.finishedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let run = try context.fetch(descriptor).first else { return nil }
        return BackfillSnapshot(
            id: run.persistentModelID, jql: run.jql, nextPageToken: run.nextPageToken,
            processedIssueCount: run.processedIssueCount,
            totalIssueCount: run.totalIssueCount,
            discovered: run.discoveredUnmappedStatuses,
            partiallyRestored: run.partiallyRestoredKeys
        )
    }

    /// 마지막으로 끝난 백필의 실패 사유. 성공했으면 nil이다.
    public func lastBackfillFailure() throws -> String? {
        var descriptor = FetchDescriptor<BackfillRun>(
            predicate: #Predicate { $0.finishedAt != nil },
            sortBy: [SortDescriptor(\.finishedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.failureMessage
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
