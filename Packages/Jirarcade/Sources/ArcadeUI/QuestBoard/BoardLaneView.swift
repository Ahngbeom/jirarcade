import SwiftUI
import ArcadeCore

/// 단계 하나의 레인 — 헤더 + 축 + 그 위에 놓인 카드들.
struct BoardLaneView: View {
    @Environment(\.arcadeTheme) private var theme
    let lane: BoardLane
    let axis: [AxisTick]
    let metrics: BoardMetrics
    /// WIP 한도. `active` 레인에만 표시한다.
    let wipLimit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ZStack(alignment: .topLeading) {
                BoardAxisView(ticks: axis, metrics: metrics)
                ForEach(lane.slots) { slot in
                    TicketCardView(slot: slot, metrics: metrics)
                        .offset(x: metrics.x(for: slot.position),
                                y: metrics.y(forRow: slot.row))
                }
            }
            .frame(height: metrics.laneHeight(rowCount: lane.rowCount),
                   alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(stageLabel)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.inkSecondary)
            Spacer()
            Text(countLabel)
                .font(.system(size: 10, design: .monospaced))
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
