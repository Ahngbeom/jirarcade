import Foundation

/// 이벤트를 시간순으로 배열하고, 각 걸음이 되돌림 쌍에 속하는지 표시한다.
///
/// 같은 티켓에서 A→B 직후 창 안에 B→A가 관측되면 그 둘을 한 쌍으로 본다. 오조작을
/// 즉시 되돌린 흔적이며, 티켓은 실제로 어디에도 가지 않았다.
///
/// **왜 따로 있나:** 채점은 이 쌍의 XP를 0으로 만들고, 시간축은 이 쌍이 정체 기준선을
/// 밀지 않게 한다. 판정이 두 곳에 복사되면 한 쌍을 두 층이 다르게 보게 되고, 그것이
/// "XP는 막혔는데 정체일은 리셋된다"는 증상의 원인이었다.
///
/// **왜 순서까지 돌려주나:** `DomainEvent`에는 안정적인 식별자가 없고 `Hashable`도 아니라
/// 되돌림 여부를 위치로 가리킬 수밖에 없다. 그런데 호출자가 자기 순서를 따로 만들면 그
/// 위치가 어긋날 수 있다 — 컴파일되고 범위도 안 벗어난 채 엉뚱한 이벤트를 건너뛴다.
/// 순서와 판정을 한 값으로 함께 돌려주면 어긋날 두 개가 애초에 생기지 않는다.
public enum RevertDetector {
    /// 시간순 순회의 한 걸음.
    public struct Step: Sendable, Equatable {
        /// **넘긴 배열**에서의 위치.
        public let index: Int
        /// 되돌림 쌍에 속하는가.
        public let isReverted: Bool

        public init(index: Int, isReverted: Bool) {
            self.index = index
            self.isReverted = isReverted
        }
    }

    /// 이벤트를 직접 담지 않은 배열(예: `[ScoredEvent]`)도 그대로 넘길 수 있다.
    /// 중간 배열을 만들지 않으므로 넘긴 배열과 인덱싱할 배열이 갈릴 수 없다.
    public static func chronology<T>(
        of items: [T],
        event: (T) -> DomainEvent,
        windowMinutes: Double
    ) -> [Step] {
        let window = windowMinutes * 60
        let order = items.indices.sorted {
            event(items[$0]).observedAt < event(items[$1]).observedAt
        }

        var paired: Set<Int> = []

        for (position, index) in order.enumerated() {
            let later = event(items[index])
            guard later.kind == .statusChanged else { continue }

            for earlierIndex in order[..<position].reversed() {
                let earlier = event(items[earlierIndex])
                guard earlier.kind == .statusChanged, earlier.issueKey == later.issueKey
                else { continue }
                guard later.observedAt.timeIntervalSince(earlier.observedAt) <= window
                else { break }

                // `nil == nil`이 참이므로 양쪽 상태를 모르는 이벤트끼리 서로의 역방향으로
                // 판정된다. 상태를 모르면 짝이 될 수 없다.
                if earlier.fromStatus == later.toStatus, earlier.toStatus == later.fromStatus,
                   earlier.fromStatus != nil, earlier.toStatus != nil {
                    paired.insert(earlierIndex)
                    paired.insert(index)
                    break
                }
            }
        }

        return order.map { Step(index: $0, isReverted: paired.contains($0)) }
    }

    public static func chronology(
        of events: [DomainEvent],
        windowMinutes: Double
    ) -> [Step] {
        chronology(of: events, event: { $0 }, windowMinutes: windowMinutes)
    }
}
