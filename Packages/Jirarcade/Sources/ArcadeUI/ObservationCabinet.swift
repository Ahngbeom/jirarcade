import SwiftUI
import ArcadeApp

/// 앱이 지금 무엇을 알고 있는지 보여준다. 2b에서 퀘스트 보드가 생겨도 남는다 —
/// 동기화가 실제로 도는지 확인하는 유일한 창이다.
@MainActor
struct ObservationCabinet: Cabinet {
    let model: AppModel

    nonisolated var id: String { "observation" }
    var title: String { "OBSERVATION" }
    var accentToken: String { "good" }

    var marqueeLines: [String] {
        var lines = ["관측 \(model.observationDays)일차"]
        // HUD와 **같은 값**을 읽는다. 예전에는 동기화 경로가 따로 담아 둔 요약을 읽어,
        // 백필 직후부터 다음 동기화까지 이 줄과 HUD가 서로 다른 레벨을 보여줬다.
        if let summary = model.lifetimeSummary {
            lines.append("LV.\(summary.level) · \(summary.totalXP) XP")
        }
        // "아직 동기화 전"은 `lastSync`로만 판정한다. 집계값은 첫 동기화 전에도 백필이
        // 넣은 이벤트로 채워지므로, 그것으로 판정하면 이 안내가 영영 뜨지 않는다.
        if model.lastSync == nil {
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
    @Environment(\.arcadeMetrics) private var metrics
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowGap) {
            Text("OBSERVATION")
                .arcadeType(.marquee, .m)
                .foregroundStyle(theme.good)

            stat("관측", "\(model.observationDays)일차")
            if let summary = model.lifetimeSummary {
                stat("레벨", "LV.\(summary.level)")
                stat("경험치", "\(summary.totalXP) XP")
                stat("다음 레벨까지", "\(summary.xpForNextLevel - summary.xpIntoLevel) XP")
            }
            // 백필만 돌린 사용자에게는 레벨과 이 안내가 함께 뜬다 — 그게 사실이다.
            // 숫자는 이미 쌓인 이벤트에서 나왔고, 지금 티켓의 변화는 아직 안 봤다.
            if model.lastSync == nil {
                Text("아직 동기화 전입니다. 첫 동기화가 끝나면 지금 티켓의 변화도 반영됩니다.")
                    .arcadeType(.prose, .m)
                    .foregroundStyle(theme.inkTertiary)
            }
            if let sync = model.lastSync {
                stat("마지막 동기화 티켓", "\(sync.observedIssueCount)건")
                if let note = sync.note {
                    Text(note).arcadeType(.prose, .m).foregroundStyle(theme.inkTertiary)
                }
            }
            if !model.unmappedStatuses.isEmpty {
                Text("매핑되지 않은 상태: \(model.unmappedStatuses.joined(separator: ", "))")
                    .arcadeType(.prose, .m)
                    .foregroundStyle(theme.danger)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: metrics.size(.formMaxWidth), alignment: .leading)
        .padding(metrics.gutter)
    }

    /// 라벨과 값이 좌우로 갈리는 한 줄. 값은 스코어보드(readout), 라벨은 문장이다.
    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).arcadeType(.prose, .m).foregroundStyle(theme.inkSecondary)
            Spacer()
            Text(value).arcadeType(.readout, .m).foregroundStyle(theme.inkPrimary).monospacedDigit()
        }
    }
}
