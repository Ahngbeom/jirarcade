import Foundation

/// 되돌림 쌍에 속한 이벤트의 **위치**를 찾는다.
///
/// 같은 티켓에서 A→B 직후 창 안에 B→A가 관측되면 그 둘을 한 쌍으로 본다. 오조작을
/// 즉시 되돌린 흔적이며, 티켓은 실제로 어디에도 가지 않았다.
///
/// **왜 따로 있나:** 채점은 이 쌍의 XP를 0으로 만들고, 시간축은 이 쌍이 정체 기준선을
/// 밀지 않게 한다. 판정이 두 곳에 복사되면 한 쌍을 두 층이 다르게 보게 되고, 그것이
/// "XP는 막혔는데 정체일은 리셋된다"는 증상의 원인이었다.
///
/// **`DomainEvent`에는 안정적인 식별자가 없고 `Hashable`도 아니라** 위치로 가리킨다.
/// 반환값은 넘긴 배열 기준의 인덱스이므로, 호출자는 인덱싱할 그 배열을 그대로 넘겨야 한다.
public enum RevertDetector {
    public static func revertedIndices(
        in events: [DomainEvent],
        windowMinutes: Double
    ) -> Set<Int> {
        let window = windowMinutes * 60
        // 판정은 시간순으로 하되 반환은 원래 위치로 한다 — 호출자가 그 배열을 인덱싱한다.
        let order = events.indices.sorted {
            events[$0].observedAt < events[$1].observedAt
        }

        var paired: Set<Int> = []

        for (position, index) in order.enumerated() {
            let later = events[index]
            guard later.kind == .statusChanged else { continue }

            for earlierIndex in order[..<position].reversed() {
                let earlier = events[earlierIndex]
                guard earlier.kind == .statusChanged, earlier.issueKey == later.issueKey
                else { continue }
                guard later.observedAt.timeIntervalSince(earlier.observedAt) <= window
                else { break }

                if earlier.fromStatus == later.toStatus, earlier.toStatus == later.fromStatus,
                   earlier.fromStatus != nil, earlier.toStatus != nil {
                    paired.insert(earlierIndex)
                    paired.insert(index)
                    break
                }
            }
        }

        return paired
    }
}
