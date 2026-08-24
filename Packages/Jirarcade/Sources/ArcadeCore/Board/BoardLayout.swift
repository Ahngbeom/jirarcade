import Foundation

/// 마감까지 남은 상태. 강조 기준(D-3 이내를 눈에 띄게 할지 등)은 **뷰가 정한다** —
/// `ArcadeCore`는 사실만 담고 표시 정책을 갖지 않는다.
public enum DueState: Sendable, Equatable {
    case none
    case dueIn(days: Int)
    case overdue(days: Int)
}

/// 축 위에 놓인 티켓 하나.
public struct BoardSlot: Sendable, Equatable, Identifiable {
    public var id: String { issue.key }

    public let issue: ObservedIssue
    /// 클램프 전 **실제** 정체일. 축에서는 접혀도 카드는 이 값을 그대로 적는다.
    public let daysStagnant: Int
    public let tier: StagnationTier
    /// 축 위 0.0…1.0 위치.
    public let position: Double
    /// 겹침 해소 결과. 0이 맨 위 줄이다.
    public let row: Int
    /// 관측 이력이 없어 `jiraUpdatedAt`으로 폴백했다.
    public let isApproximate: Bool
    public let dueState: DueState

    public init(
        issue: ObservedIssue, daysStagnant: Int, tier: StagnationTier,
        position: Double, row: Int, isApproximate: Bool, dueState: DueState
    ) {
        self.issue = issue
        self.daysStagnant = daysStagnant
        self.tier = tier
        self.position = position
        self.row = row
        self.isApproximate = isApproximate
        self.dueState = dueState
    }
}

public struct BoardLane: Sendable, Equatable, Identifiable {
    public var id: Stage { stage }

    public let stage: Stage
    public let slots: [BoardSlot]
    /// 뷰가 레인 높이를 정할 때 쓴다. 슬롯이 없으면 0이다.
    public let rowCount: Int

    public init(stage: Stage, slots: [BoardSlot], rowCount: Int) {
        self.stage = stage
        self.slots = slots
        self.rowCount = rowCount
    }
}

public struct BoardSnapshot: Sendable, Equatable {
    public let lanes: [BoardLane]
    /// 어느 레인에도 들어가지 못한 티켓. 화면이 따로 보여줘야 사라지지 않는다.
    public let unmappedIssues: [ObservedIssue]
    public let axis: [AxisTick]

    public init(lanes: [BoardLane], unmappedIssues: [ObservedIssue], axis: [AxisTick]) {
        self.lanes = lanes
        self.unmappedIssues = unmappedIssues
        self.axis = axis
    }
}

/// 미러와 이벤트 로그를 화면에 놓을 좌표로 옮긴다. 순수 함수이며 화면을 모른다.
public enum BoardLayout {
    /// 보드가 그리는 단계. **`done`은 없다** — 동기화 JQL이 `statusCategory != Done`이라
    /// 미러에 완료 티켓이 없고, 영구히 빈 레인은 "뭔가 들어와야 하는데 비어 있다"는
    /// 잘못된 신호다. 전이로 완료한 티켓은 다음 동기화에서 미러에서 사라진다.
    public static let visibleStages: [Stage] = [.backlog, .active, .review, .verify]

    /// - Parameter minimumSpacing: 슬롯이 같은 줄에 놓이기 위한 최소 간격(축 대비 비율).
    ///   `ArcadeCore`는 카드 폭도 화면 폭도 모르므로 뷰가 계산해 넘긴다.
    public static func snapshot(
        issues: [ObservedIssue],
        statusEnteredAt: [String: Date],
        workflow: WorkflowMap,
        rules: RuleSet,
        minimumSpacing: Double,
        now: Date,
        calendar: Calendar
    ) -> BoardSnapshot {
        let classifier = StagnationClassifier(rules: rules)
        var byStage: [Stage: [BoardSlot]] = [:]
        var unmapped: [ObservedIssue] = []

        for issue in issues {
            guard let stage = workflow.stage(for: issue.statusName) else {
                unmapped.append(issue)
                continue
            }
            guard visibleStages.contains(stage) else { continue }

            let entered = statusEnteredAt[issue.key]
            let stagnant = classifier.daysStagnant(
                statusEnteredAt: entered, jiraUpdatedAt: issue.jiraUpdatedAt, now: now
            )
            byStage[stage, default: []].append(BoardSlot(
                issue: issue,
                daysStagnant: stagnant,
                tier: classifier.classify(
                    statusEnteredAt: entered, jiraUpdatedAt: issue.jiraUpdatedAt, now: now
                ),
                position: BoardAxis.position(forDays: stagnant, rules: rules),
                row: 0,
                isApproximate: classifier.isApproximate(statusEnteredAt: entered),
                dueState: dueState(for: issue, now: now, calendar: calendar)
            ))
        }

        let lanes = visibleStages.map { stage in
            let packed = LanePacker.pack(byStage[stage] ?? [],
                                         minimumSpacing: minimumSpacing)
            // rowCount는 "가장 큰 row + 1"이다. 빈 레인은 -1 + 1 = 0이 되어
            // 뷰가 높이를 0으로 잡는다.
            return BoardLane(stage: stage, slots: packed,
                             rowCount: (packed.map(\.row).max() ?? -1) + 1)
        }

        // 미매핑 목록도 결정적이어야 한다 — 입력은 미러 딕셔너리 순회에서 오므로 불안정하다.
        return BoardSnapshot(
            lanes: lanes,
            unmappedIssues: unmapped.sorted { $0.key < $1.key },
            axis: BoardAxis.ticks(rules: rules)
        )
    }

    /// 마감 비교는 로컬 달력의 날짜 단위로 한다(v0.1 스펙 §8.6). `DueDate`가 그 규칙을
    /// 이미 갖고 있으므로 여기서 `Date`끼리 비교하지 않는다.
    static func dueState(for issue: ObservedIssue, now: Date, calendar: Calendar) -> DueState {
        guard let due = issue.dueDate else { return .none }
        let remaining = DueDate.daysRemaining(until: due, from: now, calendar: calendar)
        return remaining < 0 ? .overdue(days: -remaining) : .dueIn(days: remaining)
    }
}
