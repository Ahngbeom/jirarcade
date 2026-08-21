import SwiftUI
import ArcadeApp

/// 설정 화면. 아케이드 플로어의 상태 표시줄에서 시트로 연다.
///
/// 백필은 자동으로 돌지 않는다(AppModel.startBackfill 참고). 그래서 이 화면이
/// 사용자가 백필을 시작·중단·재개할 수 있는 유일한 창구다. 매핑 마법사도 마찬가지다 —
/// 첫 설정을 끝내면 `routeAfterAuthentication()`이 다시는 마법사로 보내지 않으므로,
/// 여기 있는 "매핑 수정하기"가 백필이 발견한 과거 상태를 바로잡을 유일한 입구다.
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

            mappingSection

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

            // "돌고 있는가"는 `isBackfilling`으로 판정한다. `backfillProgress != nil`로 보면
            // 첫 페이지를 다 처리할 때까지(실측 수십 초) 아래의 "과거 기록 불러오기" 버튼이
            // 활성 상태로 남아, 사용자에게는 버튼이 먹지 않은 것처럼 보인다.
            if model.isBackfilling {
                backfillProgressView
                Button("중단") { model.cancelBackfill() }
                Text("중단해도 지금까지 불러온 기록은 남고, 나중에 이어서 받을 수 있습니다.")
                    .font(.caption2)
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.hasResumableBackfill {
                Button("이어서 불러오기") {
                    Task { await model.resumeBackfillIfAvailable() }
                }
                // 이어받기는 중단 지점부터만 훑는다 — 1회차에 상태 목록을 못 받은 채
                // 지나간 티켓은 이어받기로는 영영 다시 해석되지 않는다. 그때 떨어진
                // 정확도를 회복하는 길은 처음부터 다시 훑는 것뿐이다.
                Button("처음부터 다시 불러오기") {
                    Task { await model.startBackfill() }
                }
                Text("처음부터 받으면 중단 지점은 버려지고 모든 티켓을 다시 읽습니다. 이미 기록한 이력은 중복되지 않습니다.")
                    .font(.caption2)
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// 진행률은 첫 페이지를 다 처리한 뒤에야 온다. 그 전에도 "지금 돌고 있다"는 사실은
    /// 보여줘야 하므로 세 갈래로 나뉜다: 총계를 아는 확정 바, 처리한 수만 아는 불확정 바,
    /// 아직 아무것도 모르는 시작 직후. 총계를 모를 때 처리한 수를 총계로 삼으면
    /// 진행률이 늘 100%로 보인다.
    @ViewBuilder
    private var backfillProgressView: some View {
        if let progress = model.backfillProgress {
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
        } else {
            ProgressView {
                Text("불러오는 중…")
                    .font(.caption)
                    .foregroundStyle(theme.inkSecondary)
            }
            .tint(theme.accent)
        }
    }

    /// 매핑 마법사로 돌아가는 입구. 백필이 발견한 과거 상태는 statusCategory에서 끌어낸
    /// 추정으로 채점되고 있으므로(방향까지 틀릴 수 있다), 사용자가 바로잡을 길이 필요하다.
    private var mappingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("워크플로 매핑")
                .font(.headline)
                .foregroundStyle(theme.inkPrimary)
            Text("상태 이름을 게임의 진행 단계에 연결합니다. 과거 기록을 불러온 뒤에는 그때 발견된 상태도 함께 뜹니다.")
                .font(.callout)
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.historyDiscoveredStatuses.isEmpty {
                Text("과거 이력에서 찾은 상태 \(model.historyDiscoveredStatuses.count)개가 추정값으로 채점되고 있습니다.")
                    .font(.caption)
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("매핑 수정하기") {
                // 마법사는 이 시트 뒤의 루트 화면에서 열린다 — 먼저 닫지 않으면
                // 사용자가 마법사를 덮은 설정 화면을 보게 된다.
                dismiss()
                Task { await model.reopenMapping() }
            }
        }
    }
}
