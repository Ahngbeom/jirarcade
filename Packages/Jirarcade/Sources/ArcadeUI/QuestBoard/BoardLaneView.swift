import SwiftUI
import ArcadeCore
import ArcadeApp

/// 단계 하나의 레인 — 헤더 + 축 + 그 위에 놓인 카드들.
struct BoardLaneView: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var density
    let lane: BoardLane
    let axis: [AxisTick]
    let metrics: BoardMetrics
    let model: AppModel
    let cardNamespace: Namespace.ID
    /// WIP 한도. `active` 레인에만 표시한다.
    let wipLimit: Int?
    let onOpenDetail: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: density.tightGap) {
            header
            ZStack(alignment: .topLeading) {
                BoardAxisView(ticks: axis, metrics: metrics)
                ForEach(lane.slots) { slot in
                    TicketCardView(
                        slot: slot, metrics: metrics, model: model,
                        pending: model.pendingTransitions[slot.issue.key],
                        failure: model.transitionFailures[slot.issue.key],
                        onOpenDetail: onOpenDetail
                    )
                    .offset(x: metrics.x(for: slot.position),
                            y: metrics.y(forRow: slot.row))
                    // 레인이 달라져도 같은 카드로 인식되게 한다. 이 id가 없으면
                    // SwiftUI가 옛 카드를 지우고 새 카드를 그려 이동이 보이지 않는다.
                    .matchedGeometryEffect(id: slot.issue.key, in: cardNamespace)
                }
            }
            .frame(height: metrics.laneHeight(rowCount: lane.rowCount),
                   alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: density.tightGap) {
            Text(stageLabel)
                .arcadeType(.readout, .m, weight: .bold)
                .foregroundStyle(theme.inkSecondary)
            Spacer()
            Text(countLabel)
                .arcadeType(.readout, .s)
                .foregroundStyle(overWIP ? theme.danger : theme.inkTertiary)
                .monospacedDigit()
        }
    }

    private var stageLabel: String {
        switch lane.stage {
        case .backlog: return "BACKLOG"
        case .active:  return "ACTIVE"
        case .review:  return "REVIEW"
        case .verify:  return "VERIFY"
        case .done:    return "DONE"
        }
    }

    private var overWIP: Bool {
        guard let wipLimit else { return false }
        return lane.slots.count > wipLimit
    }

    private var countLabel: String {
        guard let wipLimit else { return "\(lane.slots.count)건" }
        return overWIP
            ? "\(lane.slots.count)건 · 한도 \(wipLimit) ⚠"
            : "\(lane.slots.count)건 · 한도 \(wipLimit)"
    }
}
