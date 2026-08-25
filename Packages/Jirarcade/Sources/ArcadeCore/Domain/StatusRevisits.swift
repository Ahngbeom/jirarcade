import Foundation

/// 티켓이 **이미 거쳐 간 상태로 돌아온** 횟수.
///
/// 정체일은 마지막 상태 변화 이후를 센다. 그래서 3주 동안 진행 중 ↔ 검토를 오간 티켓도
/// 방금 옮겼다면 정체일이 0이다. 숫자 자체는 정직하지만 그것만 보면 공전 중이라는 사실이
/// 화면에서 사라진다. 이 값이 그 맥락을 되돌려준다.
///
/// **표시 전용이다.** 채점의 입력이 되지 않는다.
public enum StatusRevisits {
    public static func counts(
        from events: [DomainEvent],
        revertWindowMinutes: Double
    ) -> [String: Int] {
        // 오조작을 즉시 되돌린 흔적은 돌아온 것으로 세지 않는다 — 티켓은 어디에도 가지
        // 않았고, 세면 잘못 누른 것만으로 "왕복 중"이라는 낙인이 붙는다.
        // 순서도 검출기가 만든다 — 입력 순서를 믿지 않는다(백필은 과거 이벤트를 나중에 넣는다).
        var byIssue: [String: [DomainEvent]] = [:]
        for step in RevertDetector.chronology(of: events, windowMinutes: revertWindowMinutes) {
            guard step.isReverted == false else { continue }
            let event = events[step.index]
            // no-op 판정은 `StatusTimeline`이 한 번만 정의한다. 여기에 같은 비교를
            // 다시 쓰면, 정의가 넓어질 때(상태명 공백 제거·대소문자 무시 같은) 왕복
            // 횟수와 정체 기준선이 서로 다른 규칙 위에서 갈린다.
            guard event.kind == .statusChanged,
                  event.fromStatus != nil, event.toStatus != nil,
                  StatusTimeline.isNoOpTransition(event) == false
            else { continue }
            byIssue[event.issueKey, default: []].append(event)
        }

        var counts: [String: Int] = [:]
        for (key, ordered) in byIssue {
            guard let first = ordered.first, let opening = first.fromStatus else { continue }

            var visited: Set<String> = [opening]
            var returns = 0
            for event in ordered {
                guard let destination = event.toStatus else { continue }
                // **검사가 먼저다.** 넣고 검사하면 첫 이벤트조차 자기 자신 때문에 세어진다.
                if visited.contains(destination) { returns += 1 }
                visited.insert(destination)
            }
            if returns > 0 { counts[key] = returns }
        }
        return counts
    }
}
