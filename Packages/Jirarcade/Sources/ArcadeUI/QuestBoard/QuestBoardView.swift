import SwiftUI
import ArcadeApp

/// 퀘스트 보드 전체 화면.
struct QuestBoardView: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: AppModel
    @Namespace private var cardNamespace
    @State private var mode: BoardViewMode = .default
    @State private var detailTarget: DetailTarget?

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
            VStack(spacing: 0) {
                HStack(spacing: metrics.sectionGap) {
                    BoardHUDView(model: model)
                    Picker("보기", selection: $mode) {
                        ForEach(BoardViewMode.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .padding(.trailing, metrics.gutter)
                }
                Divider().overlay(theme.line)

                // 티켓이 하나도 없으면 두 보기 모두 할 말이 같다. 빈 우주를 그리는 대신
                // 보드가 쓰던 안내를 그대로 쓴다.
                if model.issues.isEmpty {
                    ScrollView {
                        emptyState.padding(metrics.gutter)
                    }
                } else {
                    Group {
                        switch mode {
                        case .lanes:
                            lanes(width: geometry.size.width)
                        case .orbit:
                            OrbitView(model: model, cardNamespace: cardNamespace,
                                      onOpenDetail: { key in detailTarget = DetailTarget(id: key) })
                        }
                    }
                    // 카드와 행성이 같은 `cardNamespace`를 쓰므로, 모드가 바뀔 때
                    // 이 애니메이션이 둘을 이어 준다 — 카드가 사라지고 행성이 나타나는
                    // 것이 아니라 카드가 행성으로 접힌다.
                    .animation(reduceMotion ? nil : .spring(duration: 0.45), value: mode)
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.35),
                       value: model.pendingTransitions)
        }
        .background(theme.surfaceBase)
        // 시트는 환경을 물려받지 않는다. 테마만 다시 주입하고 밀도를 빠뜨리면 시트 안쪽만
        // 최소 밀도(compact)로 떨어져, 같은 라벨이 보드와 시트에서 다른 크기로 보인다
        // (ArcadeFloorView.statusBar의 설정 시트와 같은 배선).
        .sheet(item: $detailTarget) { target in
            TicketDetailSheet(issueKey: target.id, model: model)
                .frame(minWidth: metrics.size(.sheetMinWidth),
                       minHeight: metrics.size(.sheetMinHeight))
                .environment(\.arcadeTheme, theme)
                .environment(\.arcadeMetrics, metrics)
        }
    }

    /// 레인 보기. 보드 스냅샷을 여기서 만드는 이유는 궤도 보기일 때 그 계산을
    /// 하지 않기 위해서다 — 순수 함수라 비싸지는 않지만, 쓰지 않는 좌표를 매 렌더마다
    /// 만들 이유도 없다.
    private func lanes(width: Double) -> some View {
        let board = BoardMetrics(
            availableWidth: max(width - metrics.gutter * 2, 200),
            metrics: metrics
        )
        let snapshot = model.boardSnapshot(minimumSpacing: board.minimumSpacing)

        return ScrollView {
            VStack(alignment: .leading, spacing: metrics.sectionGap) {
                ForEach(snapshot.lanes) { lane in
                    BoardLaneView(
                        lane: lane, axis: snapshot.axis, metrics: board,
                        model: model, cardNamespace: cardNamespace,
                        wipLimit: lane.stage == .active ? model.wipLimit : nil,
                        onOpenDetail: { key in detailTarget = DetailTarget(id: key) }
                    )
                }
                if !snapshot.unmappedIssues.isEmpty {
                    UnmappedLaneView(issues: snapshot.unmappedIssues, model: model)
                }
            }
            .padding(metrics.gutter)
        }
    }
}

/// `sheet(item:)`이 `Identifiable`을 요구한다. 티켓 키 자체가 식별자이므로
/// 얇게 감싸기만 한다.
private struct DetailTarget: Identifiable {
    let id: String
}
