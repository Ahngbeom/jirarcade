import Foundation
import SwiftData

/// 이벤트의 출처. **문자열 값을 바꾸지 마라** — SwiftData에 그대로 저장되므로
/// 값이 바뀌면 이미 기록된 레코드의 의미가 달라진다.
public enum EventOrigin {
    public static let observed = "observed"
    public static let backfill = "backfill"
}

@Model
public final class IssueSnapshot {
    @Attribute(.unique) public var key: String
    public var summary: String
    public var statusName: String
    public var issueType: String
    public var priority: String?
    public var assigneeAccountId: String?
    public var assigneeName: String?
    public var dueDate: Date?
    public var jiraUpdatedAt: Date
    public var firstObservedAt: Date
    public var lastObservedAt: Date

    public init(
        key: String, summary: String, statusName: String, issueType: String,
        priority: String?, assigneeAccountId: String?, assigneeName: String?,
        dueDate: Date?, jiraUpdatedAt: Date, firstObservedAt: Date, lastObservedAt: Date
    ) {
        self.key = key
        self.summary = summary
        self.statusName = statusName
        self.issueType = issueType
        self.priority = priority
        self.assigneeAccountId = assigneeAccountId
        self.assigneeName = assigneeName
        self.dueDate = dueDate
        self.jiraUpdatedAt = jiraUpdatedAt
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
    }
}

/// append-only 이벤트 로그. 이 타입을 수정하거나 삭제하는 코드를 작성하지 않는다.
@Model
public final class IssueEventRecord {
    public var issueKey: String
    public var kindRaw: String
    public var fromStatus: String?
    public var toStatus: String?
    public var observedAt: Date
    public var actorAccountId: String?
    /// `DomainEvent.priorUpdatedAt` — 이 변화 직전 미러의 `jiraUpdatedAt`.
    /// 정체 기준선이며 기록 시점에만 알 수 있다. 옵셔널이라 기존 스토어에 lightweight 추가된다.
    public var priorUpdatedAt: Date?
    /// `DomainEvent.dueDateAtObservation` — 관측 시점의 마감일.
    /// 마감 전 완료 보너스가 미러가 아니라 이 값을 본다.
    public var dueDateAtObservation: Date?
    /// Jira changelog history의 고유 id. 백필로 만든 이벤트만 값이 있다.
    /// 같은 전이를 두 번 기록하지 않기 위한 유일한 근거다 — 시각·상태명 비교로
    /// 추측하지 않는다(같은 초에 두 전이가 일어날 수 있고, 왕복 전이는 값이 같다).
    public var sourceHistoryId: String?
    /// `EventOrigin.observed` 또는 `EventOrigin.backfill`.
    /// 관측 일수는 observed만 세야 한다 — 백필이 3년 전 이벤트를 넣었다고
    /// 관측을 3년 했다고 말하면 거짓이다(스펙 §3.1).
    ///
    /// **기본값은 프로퍼티 선언에 붙어야 한다.** SwiftData가 기존 로우를 복원할 때
    /// 커스텀 `init`을 호출하지 않으므로, `init` 파라미터 기본값만으로는 이 컬럼이
    /// 없던 레코드를 열 수 없다.
    public var origin: String = EventOrigin.observed

    public init(
        issueKey: String, kindRaw: String, fromStatus: String?, toStatus: String?,
        observedAt: Date, actorAccountId: String?, priorUpdatedAt: Date?,
        dueDateAtObservation: Date?,
        sourceHistoryId: String? = nil,
        origin: String = EventOrigin.observed
    ) {
        self.issueKey = issueKey
        self.kindRaw = kindRaw
        self.fromStatus = fromStatus
        self.toStatus = toStatus
        self.observedAt = observedAt
        self.actorAccountId = actorAccountId
        self.priorUpdatedAt = priorUpdatedAt
        self.dueDateAtObservation = dueDateAtObservation
        self.sourceHistoryId = sourceHistoryId
        self.origin = origin
    }
}

@Model
public final class SyncRunRecord {
    public var startedAt: Date
    public var finishedAt: Date?
    public var observedIssueCount: Int
    /// **실패했을 때만** 채운다. `observationDayCount`가 이 필드의 nil 여부로 성공을 판정하므로,
    /// 성공한 동기화에 정보성 문구를 넣으면 그 동기화가 관측 일수에서 통째로 배제된다.
    /// 정보는 `note`에 적는다.
    public var failureMessage: String?
    /// 성공한 동기화에 남기는 정보성 메모(예: 페치 결과 0건). 성공 판정에는 영향을 주지 않는다.
    public var note: String?

    public init(startedAt: Date) {
        self.startedAt = startedAt
        self.observedIssueCount = 0
    }
}
