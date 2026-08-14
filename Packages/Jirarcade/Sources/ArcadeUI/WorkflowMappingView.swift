import SwiftUI
import ArcadeApp
import ArcadeCore

struct WorkflowMappingView: View {
    @Environment(\.arcadeTheme) private var theme
    let model: AppModel
    let candidates: [String]

    /// 상태명 → 선택된 단계. 비어 있으면 매핑하지 않은 것이다.
    @State private var selection: [String: Stage] = [:]

    private var unmappedCount: Int { candidates.count - selection.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("워크플로 매핑")
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.accent)

            Text("이 Jira의 상태를 게임 단계에 연결해 주세요. 나중에 바꿀 수 있습니다.")
                .foregroundStyle(theme.inkSecondary)

            if candidates.isEmpty {
                Text("담당한 미완료 티켓이 없어 매핑할 상태를 찾지 못했습니다. 나중에 설정에서 지정할 수 있습니다.")
                    .foregroundStyle(theme.inkTertiary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(candidates, id: \.self) { status in
                            row(status)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            if unmappedCount > 0 && !candidates.isEmpty {
                Text("상태 \(unmappedCount)개가 매핑되지 않았습니다. 해당 티켓의 전이는 점수에 반영되지 않습니다.")
                    .font(.callout)
                    .foregroundStyle(theme.inkTertiary)
            }

            HStack {
                Text("상태 \(candidates.count)개를 내 티켓에서 찾았습니다")
                    .font(.caption)
                    .foregroundStyle(theme.inkTertiary)
                Spacer()
                Button("시작하기") {
                    Task { await model.confirmMapping(WorkflowMap(statusToStage: selection)) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: 560)
    }

    private func row(_ status: String) -> some View {
        HStack {
            Text(status)
                .foregroundStyle(theme.inkPrimary)
            Spacer()
            Picker("", selection: binding(for: status)) {
                Text("— 사용 안 함 —").tag(Stage?.none)
                ForEach(Stage.allCases, id: \.self) { stage in
                    Text(label(for: stage)).tag(Stage?.some(stage))
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func binding(for status: String) -> Binding<Stage?> {
        Binding(
            get: { selection[status] },
            set: { newValue in
                if let newValue { selection[status] = newValue }
                else { selection.removeValue(forKey: status) }
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
