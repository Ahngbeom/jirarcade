import Foundation

/// 이벤트 로그에서 티켓별 "현재 상태에 들어간 시각"을 재구성한다.
///
/// 이 값이 정체 판정의 기준선이다. `StagnationClassifier`는 `statusEnteredAt`이 nil이면
/// `jiraUpdatedAt`으로 폴백하는데, 그러면 댓글·워크로그도 기준선을 밀어 정체일이 실제보다
/// 짧게 나온다. 이벤트 로그가 있으면 언제나 그쪽이 정확하다.
public enum StatusTimeline {
    /// 이벤트 하나를 반영한다. **갱신 규칙의 유일한 정의**이며 `ScoreEngine.recompute`의
    /// 순회도 이것을 부른다.
    ///
    /// `.statusChanged`만 기준선을 옮긴다. `.touched`가 옮기면 댓글 한 줄로 정체일이
    /// 0이 되어, 이 앱이 재려는 것 자체가 사라진다.
    ///
    /// **덮어쓰기 전에 비교하지 않는다.** 호출자가 시간순으로 넣는다는 전제이며,
    /// `ScoreEngine`은 정렬된 배열을 순회하고 `latestStatusEntry`는 스스로 정렬한다.
    public static func apply(_ event: DomainEvent, to map: inout [String: Date]) {
        guard event.kind == .statusChanged else { return }
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
        let reverted = RevertDetector.revertedIndices(
            in: events, windowMinutes: revertWindowMinutes
        )
        var map: [String: Date] = [:]
        for index in events.indices.sorted(by: { events[$0].observedAt < events[$1].observedAt }) {
            guard reverted.contains(index) == false else { continue }
            let event = events[index]
            // 백필은 라이브 동기화(`DiffEngine`)와 달리 같은 상태로의 전환(no-op)을 거르지
            // 않는다. `apply`는 이 함수만의 규칙이 아니라 `ScoreEngine`도 함께 쓰는 갱신
            // 규칙의 유일한 정의라 여기서 고치지 않는다 — 대신 호출 전에 걸러, 실제로
            // 아무 데도 가지 않은 티켓의 정체일이 리셋되지 않게 한다.
            guard isNoOpTransition(event) == false else { continue }
            apply(event, to: &map)
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
