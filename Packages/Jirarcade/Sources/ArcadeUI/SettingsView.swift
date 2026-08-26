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
    @Environment(\.arcadeMetrics) private var metrics
    @Environment(\.dismiss) private var dismiss
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.sectionGap) {
            HStack {
                Text("설정")
                    .arcadeType(.marquee, .m)
                    .foregroundStyle(theme.accent)
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            historySection

            mappingSection

            Spacer(minLength: 0)
        }
        .padding(metrics.gutter)
        .frame(maxWidth: metrics.size(.wizardMaxWidth), alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surfaceBase)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: metrics.rowGap) {
            Text("과거 기록")
                .arcadeType(.readout, .m, weight: .bold)
                .foregroundStyle(theme.inkPrimary)
            Text("Jira 변경 이력을 읽어 지난 전이를 점수에 반영합니다. 내가 직접 옮긴 전이만 XP가 됩니다.")
                .arcadeType(.prose, .m)
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            rangeRow

            // "돌고 있는가"는 `isBackfilling`으로 판정한다. `backfillProgress != nil`로 보면
            // 첫 페이지를 다 처리할 때까지(실측 수십 초) 아래의 "과거 기록 불러오기" 버튼이
            // 활성 상태로 남아, 사용자에게는 버튼이 먹지 않은 것처럼 보인다.
            if model.isBackfilling {
                backfillProgressView
                Button("중단") { model.cancelBackfill() }
                Text("중단해도 지금까지 불러온 기록은 남고, 나중에 이어서 받을 수 있습니다.")
                    .arcadeType(.prose, .xs)
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
                    .arcadeType(.prose, .xs)
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure = model.lastBackfillFailure {
                    // 저장된 값은 에러 타입 이름뿐이라 그대로 보여주면 뜻이 통하지 않는다.
                    // 문장으로 감싸고 타입 이름은 괄호 안 부가 정보로만 곁들인다.
                    Text("지난 불러오기가 중단되었습니다 (\(failure)). 이어서 받을 수 있습니다.")
                        .arcadeType(.prose, .s)
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
                    .arcadeType(.prose, .s)
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 범위를 고르는 줄. 고른 범위에 몇 건이 걸리는지를 **누르기 전에** 보여준다 —
    /// 조회가 얼마나 큰지 알아야 줄일지 판단할 수 있고, 그 숫자가 이 컨트롤이 있는 이유다.
    ///
    /// 백필이 도는 동안은 잠근다. 범위는 백필 JQL의 일부라, 도는 중에 바꾸면 이어받기가
    /// 새 범위와 맞지 않아 중단 지점이 버려진다.
    private var rangeRow: some View {
        VStack(alignment: .leading, spacing: metrics.tightGap) {
            HStack(spacing: metrics.rowGap) {
                Text("범위")
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.inkTertiary)
                Picker("범위", selection: Binding(
                    get: { model.historyRange },
                    set: { model.historyRange = $0 }
                )) {
                    ForEach(HistoryRange.allCases, id: \.self) { range in
                        Text(rangeLabel(range)).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(model.isBackfilling)
            }
            Text(estimateLabel)
                .arcadeType(.readout, .xs)
                .foregroundStyle(theme.inkTertiary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        // 범위가 바뀔 때마다 다시 센다. 시트를 처음 열 때도 한 번 센다 — `id:`가 바뀌지
        // 않아도 `.task`는 뷰가 나타날 때 실행된다.
        .task(id: model.historyRange) { await model.estimateHistoryScope() }
    }

    private func rangeLabel(_ range: HistoryRange) -> String {
        switch range {
        case .quarter:  "3개월"
        case .halfYear: "6개월"
        case .year:     "1년"
        case .all:      "전체"
        }
    }

    /// 건수 문구. 근사값이라는 사실을 문장에 남긴다 — 서버가 인덱스 통계로 답하므로
    /// 실제 진행률과 몇 건 어긋날 수 있고, 그때 "약"이 없으면 앱이 틀린 것처럼 보인다.
    private var estimateLabel: String {
        switch model.historyScopeEstimate {
        case .none, .counting:
            "이 범위의 티켓 수를 세는 중…"
        case .approximately(let count):
            model.historyRange == .all
                ? "담당했던 모든 티켓 약 \(count.formatted())건의 이력을 읽습니다"
                : "이 범위에 약 \(count.formatted())건 · 그 기간에 갱신된 티켓의 이력만 읽습니다"
        case .unavailable:
            "티켓 수를 세지 못했습니다. 불러오기는 그대로 할 수 있습니다"
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
                        .arcadeType(.prose, .s)
                        .foregroundStyle(theme.inkSecondary)
                }
                .tint(theme.accent)
            } else {
                ProgressView {
                    Text("불러오는 중 \(progress.processed)건")
                        .arcadeType(.prose, .s)
                        .foregroundStyle(theme.inkSecondary)
                }
                .tint(theme.accent)
            }
        } else {
            ProgressView {
                Text("불러오는 중…")
                    .arcadeType(.prose, .s)
                    .foregroundStyle(theme.inkSecondary)
            }
            .tint(theme.accent)
        }
    }

    /// 매핑 마법사로 돌아가는 입구. 백필이 발견한 과거 상태는 statusCategory에서 끌어낸
    /// 추정으로 채점되고 있으므로(방향까지 틀릴 수 있다), 사용자가 바로잡을 길이 필요하다.
    private var mappingSection: some View {
        VStack(alignment: .leading, spacing: metrics.rowGap) {
            Text("워크플로 매핑")
                .arcadeType(.readout, .m, weight: .bold)
                .foregroundStyle(theme.inkPrimary)
            Text("상태 이름을 게임의 진행 단계에 연결합니다. 과거 기록을 불러온 뒤에는 그때 발견된 상태도 함께 뜹니다.")
                .arcadeType(.prose, .m)
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // 발견 목록이 아니라 **지금 실제로 추정이 적용되는** 상태를 센다. 발견 목록은
            // 백필 시점의 스냅샷이라 사용자가 전부 지정한 뒤에도 개수가 그대로고, 폴백이
            // 닿지 않아 0점 처리된 상태까지 섞여 "불러오지 못했습니다"와 나란히 뜬다.
            let guessed = model.guessScoredStatuses
            if !guessed.isEmpty {
                Text("과거 이력에서 찾은 상태 \(guessed.count)개가 추정값으로 채점되고 있습니다.")
                    .arcadeType(.prose, .s)
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
