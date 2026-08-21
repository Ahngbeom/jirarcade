import SwiftUI
import ArcadeApp

/// 퀘스트 보드 전체 화면.
struct QuestBoardView: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: AppModel
    @Namespace private var cardNamespace

    var body: some View {
        GeometryReader { geometry in
            let metrics = BoardMetrics(availableWidth: max(geometry.size.width - 40, 200))
            let snapshot = model.boardSnapshot(minimumSpacing: metrics.minimumSpacing)

            VStack(spacing: 0) {
                BoardHUDView(model: model)
                Divider().overlay(theme.line)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(snapshot.lanes) { lane in
                            BoardLaneView(
                                lane: lane, axis: snapshot.axis, metrics: metrics,
                                model: model, cardNamespace: cardNamespace,
                                wipLimit: lane.stage == .active ? model.wipLimit : nil
                            )
                        }
                    }
                    .padding(20)
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.35),
                       value: model.pendingTransitions)
        }
        .background(theme.surfaceBase)
    }
}
