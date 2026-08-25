import SwiftUI
import ArcadeApp
import ArcadeCore

struct WorkflowMappingView: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
    let model: AppModel
    let candidates: [String]

    /// 상태명 → 선택된 단계. 비어 있으면 매핑하지 않은 것이다.
    @State private var selection: [String: Stage]

    /// "채점하지 않음"으로 지정한 상태. `selection`에 **없는 것**과 다르다 —
    /// 그건 "아직 정하지 않았다"이고 폴백 추정이 그대로 적용된다.
    @State private var excluded: Set<String>

    /// 행에서 고를 수 있는 것. `Stage?`로는 표현되지 않는다 — "아직 정하지 않음"과
    /// "채점하지 않음"이 둘 다 nil이 되어, 잘못 추정된 상태를 **끄는 것**이 불가능해진다.
    private enum RowChoice: Hashable {
        case undecided, excluded
        case stage(Stage)
    }

    init(model: AppModel, candidates: [String]) {
        self.model = model
        self.candidates = candidates
        // 다시 열었을 때 이미 설정한 매핑이 선택된 채로 보여야 한다. 빈 상태로 시작하면
        // "시작하기"를 누르는 순간 `confirmMapping`이 selection 전체를 저장하므로
        // 기존 매핑이 통째로 덮어써진다.
        //
        // 후보 목록에 없는 항목(지금 티켓에도, 과거 이력에도 안 나온 상태)도 그대로
        // 실려 보존된다 — 화면에 안 보이는 것을 저장하는 셈이지만, 사용자가 예전에
        // 의도적으로 매핑한 값이라 지우는 것보다 낫다.
        _selection = State(initialValue: model.currentMapping.statusToStage)
        // 제외 목록도 같은 이유로 실려 보존된다 — 다시 연 마법사가 빈 집합으로 시작하면
        // 확정하는 순간 사용자가 꺼둔 상태가 전부 다시 추정 채점으로 돌아간다.
        _excluded = State(initialValue: model.currentMapping.excludedStatuses)
    }

    /// 현재 미Done 티켓에서 본 상태 + 백필이 과거 이력에서 발견한 상태.
    /// 후자에는 표시를 달아 "지금은 안 쓰지만 과거에 있던 상태"임을 알린다 —
    /// 지금 Jira에 없는 이름이 목록에 있으면 사용자가 왜 뜨는지 알 수 없다.
    private var allCandidates: [(name: String, fromHistory: Bool)] {
        let current = Set(candidates)
        let historical = Set(model.historyDiscoveredStatuses).subtracting(current)
        return current.sorted().map { ($0, false) }
             + historical.sorted().map { ($0, true) }
    }

    /// 화면에 뜬 후보 중 **어떤 방식으로도 채점되지 않는** 것의 수.
    ///
    /// 매핑되지 않은 것을 그냥 세면 안 된다 — 폴백이 있는 상태는 반영되지 **않는** 것이
    /// 아니라 추정으로 반영되고 있어서, 같은 화면의 행에 붙은 "지금은 '완료'로 추정해
    /// 채점 중입니다"와 정확히 반대되는 문장이 뜬다. 제외한 상태도 빼고 센다 —
    /// 사용자가 스스로 끈 것을 경고할 일은 아니다.
    ///
    /// `selection.count`를 빼면 안 된다 — 다시 연 마법사의 selection에는 후보 목록에 없는
    /// 기존 매핑까지 들어 있어 값이 음수로 내려간다.
    private var unscoredCount: Int {
        allCandidates.count { entry in
            selection[entry.name] == nil
                && !excluded.contains(entry.name)
                && model.currentFallbacks.stage(for: entry.name) == nil
        }
    }

    /// 후보 개수 문구. 과거 이력에서 온 것이 섞여 있으면 출처를 함께 밝힌다 —
    /// "내 티켓에서 찾았습니다"만 남으면 개수와 목록이 어긋나 보인다.
    private var candidateSummary: String {
        let fromHistory = allCandidates.count(where: \.fromHistory)
        guard fromHistory > 0 else {
            return "상태 \(allCandidates.count)개를 내 티켓에서 찾았습니다"
        }
        return "상태 \(allCandidates.count)개를 찾았습니다 (과거 이력 \(fromHistory)개 포함)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.sectionGap) {
            Text("워크플로 매핑")
                .arcadeType(.marquee, .l)
                .foregroundStyle(theme.accent)

            Text("이 Jira의 상태를 게임 단계에 연결해 주세요. 나중에 바꿀 수 있습니다.")
                .arcadeType(.prose, .l)
                .foregroundStyle(theme.inkSecondary)

            if allCandidates.isEmpty {
                Text("담당한 미완료 티켓이 없어 매핑할 상태를 찾지 못했습니다. 나중에 설정에서 지정할 수 있습니다.")
                    .arcadeType(.prose, .m)
                    .foregroundStyle(theme.inkTertiary)
                    .padding(.vertical, metrics.rowGap)
            } else {
                ScrollView {
                    VStack(spacing: metrics.rowGap) {
                        ForEach(allCandidates, id: \.name) { entry in
                            row(entry)
                        }
                    }
                }
                // 목록이 화면 전체를 먹지 않도록 위아래로 묶어 둔다. 넓은 창에서는
                // 이 높이가 함께 자라 스크롤 없이 더 많은 상태가 한눈에 들어온다.
                .frame(maxHeight: metrics.size(.sheetMinHeight))
            }

            if unscoredCount > 0 && !allCandidates.isEmpty {
                Text("상태 \(unscoredCount)개가 매핑되지 않았습니다. 해당 티켓의 전이는 점수에 반영되지 않습니다.")
                    .arcadeType(.prose, .m)
                    .foregroundStyle(theme.inkTertiary)
            }

            HStack {
                Text(candidateSummary)
                    .arcadeType(.prose, .s)
                    .foregroundStyle(theme.inkTertiary)
                Spacer()
                Button("시작하기") {
                    Task {
                        await model.confirmMapping(
                            WorkflowMap(statusToStage: selection, excludedStatuses: excluded)
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(metrics.gutter)
        .frame(maxWidth: metrics.size(.wizardMaxWidth))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ entry: (name: String, fromHistory: Bool)) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: metrics.tightGap / 2) {
                Text(entry.name)
                    .arcadeType(.prose, .m)
                    .foregroundStyle(theme.inkPrimary)
                if entry.fromHistory {
                    Text("과거 이력에서 발견")
                        .arcadeType(.prose, .xs)
                        .foregroundStyle(theme.inkTertiary)
                }
                // 고르지 않은 상태도 실제로는 폴백이 추정한 단계로 채점되고 있다. 그 사실을
                // 보여주지 않으면 사용자는 무엇을 고쳐야 하는지 알 수 없다 — 실물에서
                // 보류 성격의 상태가 done으로 추정돼 마감 보너스까지 받고 있었다.
                //
                // 이 값을 초기 선택으로 채우지는 않는다. 그러면 확인만 눌러도 추정값 전부가
                // 사용자 매핑으로 승격돼 이후 폴백 갱신이 영영 이기지 못한다.
                if let guess = model.currentFallbacks.stage(for: entry.name),
                   selection[entry.name] == nil, !excluded.contains(entry.name) {
                    Text("지금은 '\(label(for: guess))'로 추정해 채점 중입니다")
                        .arcadeType(.prose, .xs)
                        .foregroundStyle(theme.inkTertiary)
                }
                // 껐다는 사실을 행에 남긴다 — 추정 문구가 사라지는 것만으로는
                // "꺼진 것"과 "추정할 값이 애초에 없던 것"이 구분되지 않는다.
                if excluded.contains(entry.name) {
                    Text("채점하지 않습니다 — 추정도 적용되지 않습니다")
                        .arcadeType(.prose, .xs)
                        .foregroundStyle(theme.inkTertiary)
                }
            }
            Spacer()
            Picker("", selection: binding(for: entry.name)) {
                Text("— 아직 정하지 않음 —").tag(RowChoice.undecided)
                Text("채점하지 않음").tag(RowChoice.excluded)
                ForEach(Stage.allCases, id: \.self) { stage in
                    Text(label(for: stage)).tag(RowChoice.stage(stage))
                }
            }
            .labelsHidden()
            .frame(width: metrics.size(.progressBarWidth) + 60)
        }
        .padding(.horizontal, metrics.sectionGap)
        .padding(.vertical, metrics.rowGap)
        .background(theme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// 제외와 매핑은 동시에 성립할 수 없다(하나는 "채점하지 마라", 다른 하나는 "이 단계로
    /// 채점하라"다). 한쪽을 고르면 다른 쪽을 반드시 지워, 모순된 조합이 애초에 저장되지
    /// 않게 한다 — 실효 맵은 매핑을 우선하므로, 남겨두면 사용자가 껐다고 믿는 상태가
    /// 계속 채점된다.
    private func binding(for status: String) -> Binding<RowChoice> {
        Binding(
            get: {
                if let stage = selection[status] { return .stage(stage) }
                return excluded.contains(status) ? .excluded : .undecided
            },
            set: { choice in
                switch choice {
                case .undecided:
                    selection.removeValue(forKey: status)
                    excluded.remove(status)
                case .excluded:
                    selection.removeValue(forKey: status)
                    excluded.insert(status)
                case .stage(let stage):
                    excluded.remove(status)
                    selection[status] = stage
                }
            }
        )
    }

    private func label(for stage: Stage) -> String {
        switch stage {
        case .backlog: "대기"
        case .active:  "진행"
        case .review:  "검토"
        case .verify:  "확인"
        case .done:    "완료"
        }
    }
}
