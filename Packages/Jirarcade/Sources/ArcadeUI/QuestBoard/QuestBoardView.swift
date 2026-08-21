import SwiftUI
import ArcadeApp

/// 퀘스트 보드 전체 화면.
struct QuestBoardView: View {
    @Environment(\.arcadeTheme) private var theme
    let model: AppModel

    var body: some View {
        GeometryReader { geometry in
            // 축이 쓸 수 있는 폭. 좌우 여백을 빼고 남는 만큼이다.
            let metrics = BoardMetrics(availableWidth: max(geometry.size.width - 40, 200))
            let snapshot = model.boardSnapshot(minimumSpacing: metrics.minimumSpacing)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(snapshot.lanes) { lane in
                        BoardLaneView(
                            lane: lane, axis: snapshot.axis, metrics: metrics,
                            wipLimit: lane.stage == .active ? model.wipLimit : nil
                        )
                    }
                }
                .padding(20)
            }
        }
        .background(theme.surfaceBase)
    }
}
