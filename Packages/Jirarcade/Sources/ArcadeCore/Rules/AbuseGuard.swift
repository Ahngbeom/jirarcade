import Foundation

/// 점수 파밍을 막는 조정을 적용한다.
/// 입력은 `observedAt` 오름차순으로 정렬되어 있다고 가정하지 않고 내부에서 정렬해 판정하되,
/// 반환 배열의 순서는 입력 순서를 그대로 유지한다.
///
/// **무효화(`applyVoids`)와 일일 상한(`applyDailyCap`)이 분리된 이유:** 스펙 §5.6이
/// 상한을 "연속 보너스 적용 후"로 못박았다. `ScoreEngine`이 두 단계 사이에 연속 배수를
/// 끼워 넣어야 하므로 한 번의 호출로 묶을 수 없다.
public struct AbuseGuard: Sendable {
    private let rules: RuleSet
    private let calendar: Calendar

    public init(rules: RuleSet, calendar: Calendar) {
        self.rules = rules
        self.calendar = calendar
    }

    /// 왕복 차단과 되돌림 무효. 배수를 곱하기 **전에** 적용한다.
    public func applyVoids(to events: [ScoredEvent]) -> [ScoredEvent] {
        var working = events
        let order = chronological(working)

        voidDuplicates(&working, order: order)
        voidReverts(&working)

        return working
    }

    /// 로컬 날짜별 상한. 연속 보너스를 곱한 **뒤에** 적용한다(스펙 §5.6).
    public func applyDailyCap(to events: [ScoredEvent]) -> [ScoredEvent] {
        var working = events
        applyDailyCap(&working, order: chronological(working))
        return working
    }

    /// 그날 이미 지급된 XP를 뺀 남은 상한. 이벤트가 아닌 보너스(위생 데일리)도
    /// 같은 상한을 함께 쓰도록 `ScoreEngine`에 노출한다.
    public func remainingDailyAllowance(on day: Date, after events: [ScoredEvent]) -> Int {
        let spent = events
            .filter { calendar.startOfDay(for: $0.event.observedAt) == day }
            .reduce(0) { $0 + $1.xp }
        return max(0, rules.dailyXPCap - spent)
    }

    private func chronological(_ events: [ScoredEvent]) -> [Int] {
        events.indices.sorted { events[$0].event.observedAt < events[$1].event.observedAt }
    }

    /// 같은 티켓의 동일한 (from → to) 전이가 창 안에서 반복되면 두 번째부터 0점.
    ///
    /// `touched`도 같은 창으로 막는다. `touched`는 전이가 아니라 "무엇이든 갱신됐다"이므로
    /// 시그니처가 티켓 하나뿐이다 — 코멘트 한 줄로 최대 160 XP를 무제한 반복 수령하는
    /// 경로를 일일 상한 하나에만 맡길 수 없다.
    private func voidDuplicates(_ events: inout [ScoredEvent], order: [Int]) {
        var lastAwarded: [String: Date] = [:]
        let window = rules.duplicateWindowHours * 3_600

        for index in order {
            let event = events[index].event
            guard events[index].xp > 0, let signature = duplicateSignature(of: event) else { continue }

            if let previous = lastAwarded[signature],
               event.observedAt.timeIntervalSince(previous) <= window {
                events[index].xp = 0
            } else {
                lastAwarded[signature] = event.observedAt
            }
        }
    }

    /// 중복 판정의 단위. nil이면 이 규칙의 대상이 아니다.
    private func duplicateSignature(of event: DomainEvent) -> String? {
        switch event.kind {
        case .statusChanged:
            "\(event.issueKey)|\(event.fromStatus ?? "")|\(event.toStatus ?? "")"
        case .touched:
            "\(event.issueKey)|touched"
        case .appeared, .vanished, .dueDateChanged:
            nil
        }
    }

    /// 전이 직후 창 안에서 정확히 역방향 전이가 관측되면 원래 지급분을 회수한다.
    ///
    /// 판정은 `RevertDetector`가 한다 — 시간축도 같은 판정을 써야 한 쌍을 두 층이
    /// 다르게 보지 않는다.
    private func voidReverts(_ events: inout [ScoredEvent]) {
        let reverted = RevertDetector.revertedIndices(
            in: events.map(\.event), windowMinutes: rules.revertWindowMinutes
        )
        for index in reverted { events[index].xp = 0 }
    }

    /// 로컬 날짜별 누적이 상한을 넘으면 넘는 만큼만 깎는다(부분 지급).
    private func applyDailyCap(_ events: inout [ScoredEvent], order: [Int]) {
        var spentByDay: [Date: Int] = [:]

        for index in order where events[index].xp > 0 {
            let day = calendar.startOfDay(for: events[index].event.observedAt)
            let spent = spentByDay[day] ?? 0
            let remaining = max(0, rules.dailyXPCap - spent)
            let granted = min(events[index].xp, remaining)
            events[index].xp = granted
            spentByDay[day] = spent + granted
        }
    }
}
