import SwiftUI
import ArcadeApp

/// 설정 화면. 지금 담는 것은 과거 기록(백필) 하나뿐이다 —
/// 아케이드 플로어의 상태 표시줄에서 시트로 연다.
///
/// 백필은 자동으로 돌지 않는다(AppModel.startBackfill 참고). 그래서 이 화면이
/// 사용자가 백필을 시작·중단·재개할 수 있는 유일한 창구다.
struct SettingsView: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("설정")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.accent)
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            historySection

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(theme.surfaceBase)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("과거 기록")
                .font(.headline)
                .foregroundStyle(theme.inkPrimary)
            Text("Jira 변경 이력을 읽어 지난 전이를 점수에 반영합니다. 내가 직접 옮긴 전이만 XP가 됩니다.")
                .font(.callout)
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let progress = model.backfillProgress {
                // 총계를 모를 수 있다 — 새 검색 API는 total을 주지 않는다.
                // 그때는 불확정 바를 쓴다. 처리한 수를 총계로 삼으면 늘 100%로 보인다.
                if let total = progress.total, total > 0 {
                    ProgressView(value: Double(min(progress.processed, total)),
                                 total: Double(total)) {
                        Text("불러오는 중 \(progress.processed)/\(total)")
                            .font(.caption)
                            .foregroundStyle(theme.inkSecondary)
                    }
                    .tint(theme.accent)
                } else {
                    ProgressView {
                        Text("불러오는 중 \(progress.processed)건")
                            .font(.caption)
                            .foregroundStyle(theme.inkSecondary)
                    }
                    .tint(theme.accent)
                }
                Button("중단") { model.cancelBackfill() }
                Text("중단해도 지금까지 불러온 기록은 남고, 나중에 이어서 받을 수 있습니다.")
                    .font(.caption2)
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.hasResumableBackfill {
                Button("이어서 불러오기") {
                    Task { await model.resumeBackfillIfAvailable() }
                }
                if let failure = model.lastBackfillFailure {
                    // 저장된 값은 에러 타입 이름뿐이라 그대로 보여주면 뜻이 통하지 않는다.
                    // 문장으로 감싸고 타입 이름은 괄호 안 부가 정보로만 곁들인다.
                    Text("지난 불러오기가 중단되었습니다 (\(failure)). 이어서 받을 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button("과거 기록 불러오기") {
                    Task { await model.startBackfill() }
                }
            }

            if model.backfillWasDegraded {
                // 카탈로그를 못 받으면 폴백 ②가 꺼진 채로 돈다 — 매핑에 없는 과거
                // 상태가 전부 0점이 된다. 조용히 두면 사용자는 XP가 왜 적은지 모른다.
                Text("상태 목록을 불러오지 못해 일부 과거 상태를 인식하지 못했습니다. 다시 불러오면 더 정확해집니다.")
                    .font(.caption)
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
