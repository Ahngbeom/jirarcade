import Foundation

/// 관측한 변화의 종류.
///
/// **케이스는 추가만 한다. 개명·삭제 금지.**
/// `ArcadeStore`는 이 값을 `rawValue` 문자열로 저장하고, `loadEvents()`는 알 수 없는
/// rawValue를 조용히 버린다(ArcadeStore.swift). 개명하거나 삭제하면 그 케이스로 기록된
/// 과거 이벤트가 재집계에서 영구히 사라진다 — append-only 로그의 취지와 정반대다.
public enum EventKind: String, Codable, Sendable, CaseIterable {
    case appeared        // 조회 결과에 처음 등장
    case statusChanged   // 상태 전이 관측
    case touched         // 상태는 그대로인데 jiraUpdatedAt이 움직임
    case dueDateChanged
    case vanished        // 조회 결과에서 사라짐 (완료 또는 재할당)
}

/// 우리가 관측한 변화 한 건. 생성 후 절대 수정하지 않는다(append-only).
public struct DomainEvent: Sendable, Equatable {
    public let issueKey: String
    public let kind: EventKind
    public let fromStatus: String?
    public let toStatus: String?
    public let observedAt: Date
    /// 이 변화를 **귀속시킬** 계정. Jira 검색 응답만으로는 실제 행위자를 알 수 없으므로
    /// 관측 시점의 담당자(assignee)를 넣는 근사값이다. "누가 이 변경을 했는가"가 아니다 —
    /// 담당자와 실제로 상태를 옮긴 사람은 다를 수 있다.
    public let actorAccountId: String?
    /// 이 변화 **직전** 미러의 `jiraUpdatedAt`. 정체 기준선을 이벤트가 직접 들고 다닌다.
    ///
    /// 없으면(`.appeared`처럼 직전 값이 존재하지 않는 경우) nil이다.
    /// 이 필드가 있어야 채점이 (이벤트 로그, RuleSet)만의 함수가 된다 — 미러의
    /// `jiraUpdatedAt`은 재집계 직전에 최신값으로 덮이므로 기준선으로 쓸 수 없다.
    public let priorUpdatedAt: Date?
    /// 이 변화를 관측한 **시점의** 마감일. `priorUpdatedAt`과 같은 이유로 이벤트가 들고 다닌다.
    ///
    /// 마감 전 완료 보너스가 이 값을 쓴다. 미러의 `dueDate`를 보면 티켓이
    /// 조회 결과에서 사라진 뒤 재집계할 때 보너스가 통째로 증발한다 — 준 XP를 도로 뺏는 셈이다.
    /// 마감일이 없는 티켓이면 nil이며, 그때는 보너스도 없다.
    public let dueDateAtObservation: Date?

    public init(
        issueKey: String, kind: EventKind, fromStatus: String?, toStatus: String?,
        observedAt: Date, actorAccountId: String?, priorUpdatedAt: Date? = nil,
        dueDateAtObservation: Date? = nil
    ) {
        self.issueKey = issueKey
        self.kind = kind
        self.fromStatus = fromStatus
        self.toStatus = toStatus
        self.observedAt = observedAt
        self.actorAccountId = actorAccountId
        self.priorUpdatedAt = priorUpdatedAt
        self.dueDateAtObservation = dueDateAtObservation
    }
}

/// 이벤트에 XP를 매긴 결과. XP는 파생값이므로 이벤트와 분리한다.
public struct ScoredEvent: Sendable, Equatable {
    public let event: DomainEvent
    public var xp: Int

    public init(event: DomainEvent, xp: Int) {
        self.event = event
        self.xp = xp
    }
}
