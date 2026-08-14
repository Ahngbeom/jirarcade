import SwiftUI
import ArcadeApp

/// 앱이 지금 무엇을 알고 있는지 보여준다. 2b에서 퀘스트 보드가 생겨도 남는다 —
/// 동기화가 실제로 도는지 확인하는 유일한 창이다.
@MainActor
struct ObservationCabinet: @MainActor Cabinet {
    let model: AppModel

    var id: String { "observation" }
    var title: String { "OBSERVATION" }
    var accentToken: String { "good" }

    var marqueeLines: [String] {
        var lines = ["관측 \(model.observationDays)일차"]
        if let summary = model.summary {
            lines.append("LV.\(summary.level) · \(summary.totalXP) XP")
        } else {
            lines.append("아직 동기화 전")
        }
        if let note = model.lastSync?.note {
            lines.append(note)
        }
        return lines
    }

    func makeView() -> AnyView {
        AnyView(ObservationDetailView(model: model))
    }
}

private struct ObservationDetailView: View {
    @Environment(\.arcadeTheme) private var theme
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OBSERVATION")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.good)

            stat("관측", "\(model.observationDays)일차")
            if let summary = model.summary {
                stat("레벨", "LV.\(summary.level)")
                stat("경험치", "\(summary.totalXP) XP")
                stat("다음 레벨까지", "\(summary.xpForNextLevel - summary.xpIntoLevel) XP")
            }
            if let sync = model.lastSync {
                stat("마지막 동기화 티켓", "\(sync.observedIssueCount)건")
                if let note = sync.note {
                    Text(note).font(.callout).foregroundStyle(theme.inkTertiary)
                }
            }
            if !model.unmappedStatuses.isEmpty {
                Text("매핑되지 않은 상태: \(model.unmappedStatuses.joined(separator: ", "))")
                    .font(.callout)
                    .foregroundStyle(theme.danger)
            }
        }
        .padding(24)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(theme.inkSecondary)
            Spacer()
            Text(value).foregroundStyle(theme.inkPrimary).monospacedDigit()
        }
    }
}
