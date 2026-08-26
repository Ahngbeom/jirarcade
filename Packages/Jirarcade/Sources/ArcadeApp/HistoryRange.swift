import Foundation

/// 과거 기록(백필)을 어디까지 읽을 것인가.
///
/// **동기화에는 걸지 않는다.** 동기화는 `statusCategory != Done`으로 이미 미완료 티켓만
/// 받고, 거기에 갱신일 기준을 더하면 정체 45일짜리 티켓 — 이 게임이 보스로 보여주려는
/// 바로 그 티켓 — 이 조회에서 빠진다. 큰 조회는 완료 티켓까지 changelog를 훑는 백필이고,
/// 이 값은 그 범위만 좁힌다.
///
/// 기준은 `updated`다. `created`로 자르면 오래전 만들어져 최근까지 움직인 티켓의 이력이
/// 빠지는데, 그 이력이야말로 소급할 가치가 있는 것이다.
public enum HistoryRange: String, Sendable, CaseIterable, Equatable {
    case quarter, halfYear, year, all

    /// JQL에 덧붙일 조건. `all`이면 없다.
    public var jqlClause: String? {
        switch self {
        case .quarter:  "updated >= -90d"
        case .halfYear: "updated >= -180d"
        case .year:     "updated >= -365d"
        case .all:      nil
        }
    }

    /// 백필 JQL. 이 함수 하나가 정본이다 — `BackfillEngine`은 JQL 문자열이 같을 때만
    /// 중단된 실행을 이어받으므로, 두 곳에서 각자 조립하면 같은 범위가 다른 문자열이
    /// 되어 이어받기가 조용히 끊긴다.
    public var backfillJQL: String {
        let base = "assignee = currentUser()"
        guard let clause = jqlClause else { return base }
        return "\(base) AND \(clause)"
    }
}
