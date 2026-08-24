import SwiftUI
import ArcadeApp

/// 퀘스트 보드 전체 화면.
struct QuestBoardView: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: AppModel
    @Namespace private var cardNamespace

    /// 동기화 전과 "티켓이 없다"를 구분한다. `ObservationCabinet`이 쓰는 것과 같은
    /// 판정(`lastSync`)이다 — 집계값으로 판정하면 백필이 넣은 이벤트 때문에 이 안내가
    /// 영영 뜨지 않는다.
    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: metrics.tightGap) {
            if model.lastSync == nil {
                Text("아직 동기화하지 않았습니다.")
                    .arcadeType(.prose, .l)
                    .foregroundStyle(theme.inkSecondary)
                Text("첫 동기화가 끝나면 담당한 티켓이 여기 나타납니다.")
                    .arcadeType(.prose, .m)
                    .foregroundStyle(theme.inkTertiary)
            } else {
                Text("담당한 미완료 티켓이 없습니다.")
                    .arcadeType(.prose, .l)
                    .foregroundStyle(theme.inkSecondary)
                Text("Jira에서 티켓을 맡으면 다음 동기화에 나타납니다.")
                    .arcadeType(.prose, .m)
                    .foregroundStyle(theme.inkTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, metrics.gutter)
    }

    var body: some View {
        GeometryReader { geometry in
            let board = BoardMetrics(
                availableWidth: max(geometry.size.width - metrics.gutter * 2, 200),
                metrics: metrics
            )
            let snapshot = model.boardSnapshot(minimumSpacing: board.minimumSpacing)

            VStack(spacing: 0) {
                BoardHUDView(model: model)
                Divider().overlay(theme.line)
                ScrollView {
                    VStack(alignment: .leading, spacing: metrics.sectionGap) {
                        if model.issues.isEmpty {
                            emptyState
                        } else {
                            ForEach(snapshot.lanes) { lane in
                                BoardLaneView(
                                    lane: lane, axis: snapshot.axis, metrics: board,
                                    model: model, cardNamespace: cardNamespace,
                                    wipLimit: lane.stage == .active ? model.wipLimit : nil
                                )
                            }
                        }
                        if !snapshot.unmappedIssues.isEmpty {
                            UnmappedLaneView(issues: snapshot.unmappedIssues, model: model)
                        }
                    }
                    .padding(metrics.gutter)
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.35),
                       value: model.pendingTransitions)
        }
        .background(theme.surfaceBase)
    }
}
