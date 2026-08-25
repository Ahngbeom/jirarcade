import SwiftUI
import AppKit
import ArcadeApp
import ArcadeCore

struct ArcadeFloorView: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
    let model: AppModel

    @State private var openCabinetID: String?
    @State private var fullScreenCabinetID: String?
    @State private var showingSettings = false

    /// 셸이 아는 것은 이 배열뿐이다. 2b에서 캐비닛을 더할 때 이 줄만 늘어난다.
    private var cabinets: [any Cabinet] {
        [QuestBoardCabinet(model: model), ObservationCabinet(model: model)]
    }

    var body: some View {
        Group {
            if let id = fullScreenCabinetID,
               let cabinet = cabinets.first(where: { $0.id == id }) {
                fullScreen(cabinet)
            } else {
                floor
            }
        }
        .background(theme.surfaceBase)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            Task { await model.syncNow(reason: .foreground) }
        }
    }

    private var floor: some View {
        VStack(spacing: 0) {
            marquee
            MarqueeBulbRail()
            cabinetFloor
            Divider().overlay(theme.line)
            statusBar
        }
        .sheet(item: Binding(
            get: { openCabinetID.map(OpenCabinet.init) },
            set: { openCabinetID = $0?.id }
        )) { open in
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("닫기") { openCabinetID = nil }.keyboardShortcut(.cancelAction)
                }
                .padding(metrics.sectionGap)
                if let cabinet = cabinets.first(where: { $0.id == open.id }) {
                    cabinet.makeView()
                } else {
                    // id가 가리키는 캐비닛이 더 이상 없다 — 강제 언래핑 대신 빈 안내로 넘긴다.
                    Text("캐비닛을 찾을 수 없습니다")
                        .arcadeType(.prose, .m)
                        .foregroundStyle(theme.inkTertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(minWidth: metrics.size(.sheetMinWidth),
                   minHeight: metrics.size(.sheetMinHeight))
            .background(theme.surfaceBase)
            // 시트는 환경을 물려받지 않는다. 테마와 밀도를 **함께** 다시 주입해야
            // 시트 안팎의 글자 크기가 같아진다 — 하나만 넘기면 시트만 최소 밀도로 떨어진다.
            .environment(\.arcadeTheme, theme)
            .environment(\.arcadeMetrics, metrics)
        }
    }

    /// 전체 화면 캐비닛. 상단 줄이 플로어로 돌아가는 유일한 길이다.
    private func fullScreen(_ cabinet: any Cabinet) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: metrics.sectionGap) {
                Button("◂ FLOOR") { fullScreenCabinetID = nil }
                    .arcadeType(.readout, .m, weight: .bold)
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                    .keyboardShortcut(.cancelAction)
                Text(cabinet.title)
                    .arcadeType(.readout, .m, weight: .bold)
                    .foregroundStyle(theme.inkSecondary)
                Spacer()
            }
            .padding(.horizontal, metrics.gutter)
            .padding(.vertical, metrics.rowGap)
            Divider().overlay(theme.line)
            cabinet.makeView()
        }
    }

    /// 플로어의 간판. 제품 이름이 주인공이고 화면 이름은 그 아래 작게 붙는다 —
    /// 실제 아케이드 캐비닛의 마퀴가 게임 이름을 크게, 부제를 작게 다는 것과 같다.
    ///
    /// `▨` 장식을 뗀 이유: 워드마크가 들어온 자리에서 그 기호는 아무것도 말하지 않는다.
    private var marquee: some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.sectionGap) {
            VStack(alignment: .leading, spacing: metrics.tightGap) {
                JirarcadeWordmark(step: .l)
                Text("ARCADE FLOOR")
                    .arcadeType(.readout, .s, weight: .bold)
                    .foregroundStyle(theme.inkTertiary)
            }
            Spacer()
            // 두 배지는 다른 것을 말한다. 미매핑은 **0점 처리 중**이고, 추정은 폴백이
            // 넣은 값으로 **채점되고 있는 중**이다. 후자가 더 위험하다 — 방향이 틀린
            // 추정은 조용히 XP를 준다(보류 성격의 상태가 done으로 추정되면 어디서
            // 옮겨오든 전진으로 채점되고 마감 보너스까지 붙는다). 그런데도 이 사실은
            // 설정 시트를 열어야만 보였다.
            //
            // 색을 가르는 이유: 추정은 대개 맞다. 둘 다 `danger`로 칠하면 확인이
            // 필요한 것과 확실히 잃고 있는 것이 같은 무게로 보인다.
            if !model.unmappedStatuses.isEmpty {
                mappingBadge("⚠ 매핑되지 않은 상태 \(model.unmappedStatuses.count)개",
                             tint: theme.danger)
            }
            if !model.guessScoredStatuses.isEmpty {
                mappingBadge("⚠ 추정으로 채점 중인 상태 \(model.guessScoredStatuses.count)개",
                             tint: theme.accent)
            }
        }
        .padding(.horizontal, metrics.gutter)
        // 간판에는 위아래로 여유가 필요하다. 다른 줄과 같은 `rowGap`을 주면 워드마크가
        // 제목 표시줄에 붙어 헤더가 아니라 잘린 첫 줄처럼 보인다.
        .padding(.vertical, metrics.sectionGap)
    }

    /// 매핑 상태를 알리는 배지. 눌러서 마법사로 간다.
    ///
    /// 죽은 텍스트로 두면 무엇이 잘못됐는지 알려주고도 고칠 길을 주지 않는다.
    /// 둘 다 눌리게 하는 이유: 나란히 놓인 배지 중 하나만 반응하면 사용자는
    /// 안 되는 쪽을 고장으로 읽는다.
    private func mappingBadge(_ text: String, tint: Color) -> some View {
        Button(text) { Task { await model.reopenMapping() } }
            .buttonStyle(.plain)
            .arcadeType(.readout, .m)
            .foregroundStyle(tint)
    }

    /// 캐비닛은 **폭이 고정**이고 넘치면 다음 줄로 접힌다. 폭을 늘려 화면을 채우면
    /// 1600pt에서 세 장이 납작하게 늘어나 업라이트 캐비닛으로 보이지 않는다 —
    /// 넓어질 때 늘어나는 것은 캐비닛이 아니라 캐비닛이 **몇 대 들어가는가**여야 한다.
    ///
    /// 위쪽 정렬인 이유: 남는 세로 공간은 "아직 빈 자리"라는 사실 그대로다.
    /// 가운데 정렬하면 캐비닛 두 대가 화면 한가운데 떠 있는 그림이 된다.
    private var cabinetFloor: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(
                        .adaptive(minimum: metrics.size(.cabinetWidth),
                                  maximum: metrics.size(.cabinetWidth)),
                        spacing: metrics.sectionGap,
                        alignment: .top
                    )],
                    alignment: .center,
                    spacing: metrics.sectionGap
                ) {
                    ForEach(cabinets, id: \.id) { cabinet in
                        cabinetCard(cabinet)
                    }
                    comingSoon()
                }
                .padding(metrics.gutter)
                // 캐비닛 줄을 플로어 한가운데에 세운다. 위쪽에 붙이면 1600×960에서
                // 아래로 500pt 넘는 검은 공백이 남아 "빈 자리"가 아니라 잘린 화면으로
                // 보인다. 위아래 간판(마퀴·스코어보드 레일)이 화면 끝을 잡고 있으므로,
                // 그 사이에 기계가 늘어선 구성이 실제 아케이드 플로어에 가깝다.
                //
                // 캐비닛이 늘어 화면을 넘기면 `minHeight`가 무력해지고 그대로 스크롤된다.
                .frame(minHeight: proxy.size.height, alignment: .center)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 업라이트 캐비닛 세 밴드: 마퀴(간판) · 어트랙트 스크린 · 컨트롤 패널.
    ///
    /// 스크린 밴드에 `surfaceBase`를 쓰는 이유: 두 테마 모두에서 `surfaceRaised`보다
    /// 어두워, 색을 더 쓰지 않고도 "패인 화면"으로 읽힌다.
    private func cabinetCard(_ cabinet: any Cabinet) -> some View {
        VStack(spacing: 0) {
            Text(cabinet.title)
                .arcadeType(.readout, .m, weight: .bold)
                .foregroundStyle(theme.surfaceBase)
                .frame(maxWidth: .infinity)
                .padding(.vertical, metrics.rowGap)
                .background(theme.color(forToken: cabinet.accentToken))

            VStack(alignment: .leading, spacing: metrics.rowGap) {
                ForEach(cabinet.marqueeLines, id: \.self) { line in
                    Text(line)
                        .arcadeType(.readout, .m)
                        .foregroundStyle(theme.inkSecondary)
                        .lineLimit(1)
                }
            }
            .padding(metrics.rowGap)
            // 줄을 화면 밴드 **한가운데**에 놓는다. 위에 붙이면 캐비닛이 세로로 서는
            // 만큼 아래로 300pt 가까운 빈 칸이 남아, 잘려 나간 목록처럼 보인다.
            // 가운데에 두면 같은 여백이 화면 베젤로 읽힌다.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(theme.surfaceBase)
            .padding(metrics.tightGap)

            Divider().overlay(theme.line)

            HStack {
                Button("▶ OPEN") {
                    switch cabinet.presentation {
                    case .sheet:      openCabinetID = cabinet.id
                    case .fullScreen: fullScreenCabinetID = cabinet.id
                    }
                }
                .arcadeType(.readout, .m, weight: .bold)
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                Spacer()
            }
            .padding(.horizontal, metrics.rowGap)
            .padding(.vertical, metrics.rowGap)
        }
        .frame(width: metrics.size(.cabinetWidth), height: metrics.size(.cabinetHeight))
        .background(theme.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 빈 자리도 캐비닛과 같은 실루엣을 갖는다 — 크기가 다르면 "자리"가 아니라
    /// 레이아웃 사고처럼 보인다.
    private func comingSoon() -> some View {
        VStack {
            Spacer()
            Text("COMING SOON")
                .arcadeType(.readout, .m, weight: .bold)
                .foregroundStyle(theme.inkTertiary)
            Spacer()
        }
        .frame(width: metrics.size(.cabinetWidth), height: metrics.size(.cabinetHeight))
        .background(theme.surfaceRaised.opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 하단 스코어보드 레일. 최소 창(1120pt)에서도 한 줄에 들어가므로 밀도로 갈라
    /// 두 줄로 접지 않는다 — 같은 정보가 창 크기에 따라 다른 자리에 있으면
    /// 매일 여는 화면에서 눈이 매번 다시 찾아야 한다.
    private var statusBar: some View {
        VStack(alignment: .leading, spacing: metrics.rowGap) {
            backfillProgressRow
            HStack(spacing: metrics.sectionGap) {
                levelReadout
                Spacer()
                // 도는 동안 회전 표시를 문구 앞에 둔다. 문구만 바꾸면 정지한 글자라
                // "지금 무언가 일어나고 있다"가 읽히지 않는다 — 새로고침을 눌러도
                // 앱이 멈춘 것처럼 보였다는 것이 이 표시를 더한 이유다.
                if model.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.accent)
                }
                Text(syncText)
                    .arcadeType(.readout, .s)
                    .foregroundStyle(theme.inkTertiary)
                Button("설정") { showingSettings = true }
                    .arcadeType(.readout, .s)
                // 도는 중에는 잠근다. 연달아 누르면 스케줄러가 요청을 쌓고, 사용자는
                // 첫 번째가 끝난 것인지 두 번째가 시작된 것인지 알 수 없다.
                Button("새로고침") { Task { await model.syncNow() } }
                    .arcadeType(.readout, .s)
                    .disabled(model.isSyncing)
            }
        }
        .padding(.horizontal, metrics.gutter)
        .padding(.vertical, metrics.rowGap)
        // 캐비닛 시트와 같은 뷰에 시트를 두 개 붙이지 않는다 — 상태 표시줄에 붙여
        // 각자 하나씩 갖게 한다. 시트는 환경을 물려받지 않으므로 다시 주입한다.
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model)
                .frame(minWidth: metrics.size(.sheetMinWidth),
                       minHeight: metrics.size(.sheetMinHeight))
                .environment(\.arcadeTheme, theme)
                .environment(\.arcadeMetrics, metrics)
        }
    }

    /// 백필이 도는 동안만 보인다. 설정을 닫아도 진행 상황을 볼 수 있어야 한다 —
    /// 백필은 몇 분씩 걸리고 그동안 사용자가 설정 화면에 붙들려 있을 이유가 없다.
    @ViewBuilder
    private var backfillProgressRow: some View {
        // 설정 화면과 같은 이유로 `isBackfilling`으로 판정한다 — 진행률은 첫 페이지를
        // 다 처리한 뒤에야 오므로, 그때까지 아무것도 안 뜨면 시작한 티가 나지 않는다.
        if model.isBackfilling {
            HStack(spacing: metrics.tightGap) {
                // nil을 넘기면 불확정 바가 된다 — 총계를 모르는 동안 쓰는 표시다.
                ProgressView(value: backfillFraction)
                    .tint(theme.accent)
                    .frame(width: metrics.size(.progressBarWidth))
                Text(backfillProgressText)
                    .arcadeType(.readout, .s)
                    .foregroundStyle(theme.inkSecondary)
            }
        }
    }

    /// 총계를 알 때만 확정 비율이 된다. 모를 때 처리한 수를 총계로 삼으면 늘 100%로 보인다.
    /// 근사 총계라 실제 처리 수가 총계를 넘을 수 있어 클램프한다.
    private var backfillFraction: Double? {
        guard let progress = model.backfillProgress,
              let total = progress.total, total > 0 else { return nil }
        return Double(min(progress.processed, total)) / Double(total)
    }

    private var backfillProgressText: String {
        guard let progress = model.backfillProgress else { return "과거 기록 불러오는 중…" }
        if let total = progress.total, total > 0 {
            return "과거 기록 \(progress.processed)/\(total)"
        }
        return "과거 기록 \(progress.processed)건"
    }

    @ViewBuilder
    private var levelReadout: some View {
        if let season = model.seasonSummary, let lifetime = model.lifetimeSummary {
            HStack(spacing: metrics.tightGap) {
                // HUD는 시즌을 보여준다 — 오늘 하나 처리한 것이 움직여야 하기 때문이다.
                Text("시즌 LV.\(season.level)")
                    .arcadeType(.readout, .l, weight: .bold)
                    .foregroundStyle(theme.accent)
                    .monospacedDigit()
                ProgressView(value: Double(season.xpIntoLevel),
                             total: Double(max(season.xpForNextLevel, 1)))
                    .tint(theme.accent)
                    .frame(width: metrics.size(.progressBarWidth))
                Text("\(season.xpIntoLevel)/\(season.xpForNextLevel)")
                    .arcadeType(.readout, .s)
                    .foregroundStyle(theme.inkSecondary)
                    .monospacedDigit()
                // 통산은 옆에 조용히 둔다.
                Text("통산 LV.\(lifetime.level)")
                    .arcadeType(.readout, .s)
                    .foregroundStyle(theme.inkTertiary)
                    .monospacedDigit()
            }
        }
    }

    private var syncText: String {
        // `.expired`가 실패 배지보다 먼저 와야 한다(I3) — 토큰 만료는 재로그인이 필요한
        // 인증 문제이지 네트워크 문제가 아니다. 만료된 채로 재시도가 쌓이면 실패 배지도
        // 결국 뜨지만(회복 시도를 계속하기 위해 루프는 멈추지 않는다 — performSync()
        // 참고), 이미 배너가 같은 사실을 말하고 있는데 상태 표시줄이 "연결 실패"라고
        // 겹쳐 말하면 인증 문제를 네트워크 문제로 오해하게 만든다.
        if model.phase == .expired {
            return "토큰이 만료됐습니다. 다시 로그인해 주세요."
        }
        // 도는 중이면 지난 실패보다 먼저 말한다 — 지금 재시도하고 있는 중인데
        // "연결하지 못했습니다"가 떠 있으면 방금 누른 새로고침이 무시된 것처럼 읽힌다.
        if model.isSyncing {
            return "동기화 중…"
        }
        // 실패 배지가 "아직 동기화하지 않았습니다"보다 먼저 와야 한다 — 한 번도 성공한 적
        // 없이 계속 실패 중인 사용자에게 "아직 안 했다"는 태평한 문구는 오해를 준다.
        if model.schedulerState.shouldSurfaceFailure {
            return "⚠ Jira에 연결하지 못했습니다"
        }
        guard let sync = model.lastSync, let finished = sync.finishedAt else {
            return "아직 동기화하지 않았습니다"
        }
        return "마지막 동기화 \(finished.formatted(date: .omitted, time: .shortened))"
    }
}

/// sheet(item:)이 Identifiable을 요구하므로 감싼다.
private struct OpenCabinet: Identifiable { let id: String }
