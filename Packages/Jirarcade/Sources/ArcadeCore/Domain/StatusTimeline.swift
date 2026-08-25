import Foundation

/// 이벤트 로그에서 티켓별 "현재 상태에 들어간 시각"을 재구성한다.
///
/// 이 값이 정체 판정의 기준선이다. `StagnationClassifier`는 `statusEnteredAt`이 nil이면
/// `jiraUpdatedAt`으로 폴백하는데, 그러면 댓글·워크로그도 기준선을 밀어 정체일이 실제보다
/// 짧게 나온다. 이벤트 로그가 있으면 언제나 그쪽이 정확하다.
public enum StatusTimeline {
    /// 이벤트 하나를 반영한다. **정체 기준선 갱신 규칙이 전부 여기 있다** — 무엇이
    /// 기준선을 옮기는가, 그리고 무엇이 옮길 자격을 잃는가.
    ///
    /// `.statusChanged`만 기준선을 옮긴다. `.touched`가 옮기면 댓글 한 줄로 정체일이
    /// 0이 되어, 이 앱이 재려는 것 자체가 사라진다.
    ///
    /// 되돌림 쌍과 no-op 전환은 옮기지 못한다. 잘못 눌러 3초 만에 되돌린 오조작이 3주
    /// 정체를 지우면 안 되고, 같은 상태로 다시 들어간 이벤트는 티켓이 아무 데도 가지
    /// 않았다는 뜻이다.
    ///
    /// **`isReverted`를 인자로 받는 이유:** 되돌림은 이벤트 하나만 봐서는 알 수 없다
    /// (`RevertDetector`가 로그 전체를 본다). 그렇다고 가드를 호출자에게 맡기면 빼먹을
    /// 수 있고, 빼먹어도 컴파일된다. 인자로 요구하면 빼먹는 대신 거짓을 적어야 한다 —
    /// 그건 눈에 띈다.
    ///
    /// **덮어쓰기 전에 비교하지 않는다.** 호출자가 시간순으로 넣는다는 전제이며, 두
    /// 호출자 모두 `RevertDetector.chronology`가 만든 순서를 그대로 돈다.
    public static func apply(
        _ event: DomainEvent, isReverted: Bool, to map: inout [String: Date]
    ) {
        guard event.kind == .statusChanged else { return }
        guard isReverted == false else { return }
        guard isNoOpTransition(event) == false else { return }
        map[event.issueKey] = event.observedAt
    }

    /// 로그 전체를 반영한 **최종** 맵. 보드가 정체일을 계산할 때 쓴다.
    ///
    /// 되돌림 쌍은 제외한다 — 채점이 이미 0점으로 판정한 그 쌍을 시간축도 없던 일로 본다.
    /// 그러지 않으면 잘못 눌러 3초 만에 되돌린 티켓이 3주 정체를 잃는다.
    ///
    /// 입력 순서를 신뢰하지 않고 정렬한다 — `ArcadeStore.loadEvents()`의 순서는 계약이
    /// 아니고, 백필은 과거 이벤트를 나중에 넣는다. 동률은 순서가 뒤바뀌어도 같은 값을
    /// 쓰므로 타이브레이크가 필요 없다.
    public static func latestStatusEntry(
        from events: [DomainEvent],
        revertWindowMinutes: Double
    ) -> [String: Date] {
        var map: [String: Date] = [:]
        for step in RevertDetector.chronology(of: events, windowMinutes: revertWindowMinutes) {
            apply(events[step.index], isReverted: step.isReverted, to: &map)
        }
        return map
    }

    /// 같은 상태로의 전환(`fromStatus == toStatus`, 둘 다 값이 있음)인지 본다.
    ///
    /// 라이브 동기화(`DiffEngine`)는 이런 이벤트를 만들지 않지만 백필(`ChangelogParser`)은
    /// 거르지 않아 실제 로그에 남는다. `ScoreEngine.recompute`도 기준선 갱신에 같은
    /// 판정을 쓴다.
    static func isNoOpTransition(_ event: DomainEvent) -> Bool {
        guard event.kind == .statusChanged,
              let from = event.fromStatus, let to = event.toStatus
        else { return false }
        return from == to
    }
}
