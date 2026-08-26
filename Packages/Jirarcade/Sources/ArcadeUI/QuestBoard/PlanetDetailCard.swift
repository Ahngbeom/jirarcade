import SwiftUI
import ArcadeApp
import ArcadeCore

/// 행성을 눌렀을 때 궤도 위에 뜨는 관측 기록 카드.
///
/// 두 겹이다. 위쪽은 미러가 이미 아는 것(키·요약·등급·정체일·마감·이월)이라 누르는
/// 순간 그려지고, 아래쪽은 Jira에 물어야 아는 것(본문·댓글)이라 도착하는 대로 채워진다.
/// 위가 먼저 그려져야 하는 이유는 이 화면이 "어느 티켓이 왜 거기 있는가"를 답하는
/// 화면이기 때문이다 — 그 답은 미러에 있고, 본문은 그 답을 확인하는 부록이다.
///
/// 누른 행성을 카드 안에 다시 크게 그린다. 궤도의 점은 작아서 어느 것을 눌렀는지
/// 카드만 보고는 알 수 없는데, 같은 색·같은 채움·같은 마감 링을 크게 보여주면 궤도의
/// 점과 카드가 한 티켓으로 이어진다.
///
/// `TicketCardView`를 재사용하지 않는 이유는 그 뷰가 상태 옮기기 메뉴와 5초 실행 취소
/// UI를 품고 있기 때문이다 — 궤도는 보는 화면이고 전이는 레인에서 한다. 고치는 일도
/// 여기서 하지 않고 시트(`TicketDetailSheet`)로 넘긴다. 표기는 `TicketPresentation`을
/// 함께 거쳐 카드와 어긋나지 않는다.
///
/// 팝오버가 아니라 같은 뷰 트리 안의 카드인 이유: macOS 팝오버는 별도 윈도우로 떠서
/// 앱 창 바깥으로 나간다.
struct PlanetDetailCard: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
    let planet: OrbitPlanet
    let model: AppModel
    /// 카드가 화면에서 쓸 수 있는 최대 높이. 본문이 길면 그 안에서 스크롤한다.
    let maxHeight: Double
    /// 닫기. 바깥 탭과 같은 일을 하지만 버튼이 있어야 키보드로도 닿는다.
    let onClose: () -> Void
    /// 제목·댓글을 고치는 시트를 연다. 카드는 읽기 전용이다.
    let onOpenEditor: () -> Void

    /// 카드 폭. 레인 카드의 2.8배 — 본문 한 문단이 접히지 않고 읽히는 폭이면서,
    /// 최소 창(1120pt)에서도 성계가 카드 뒤로 완전히 가려지지 않는 폭이다.
    private var width: Double { metrics.size(.ticketCardWidth) * 2.8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(metrics.sectionGap)
            Divider().overlay(theme.line)
            ScrollView {
                remote
                    .padding(metrics.sectionGap)
            }
            Divider().overlay(theme.line)
            footer
                .padding(.horizontal, metrics.sectionGap)
                .padding(.vertical, metrics.rowGap)
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.surfaceRaised)
        .overlay(Rectangle().strokeBorder(theme.line, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Button("✕", action: onClose)
                .buttonStyle(.plain)
                .arcadeType(.readout, .s)
                .foregroundStyle(theme.inkTertiary)
                .padding(metrics.rowGap)
                // Esc로도 닫힌다 — 카드가 열린 채 키보드만 쓰는 경우의 유일한 출구다.
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - 미러가 아는 것

    /// 행성 + 스코어보드. 왼쪽의 행성은 궤도의 그것과 같은 뷰(`PlanetView`)를 크게
    /// 그린 것이라, 등급 색·raid 채움·마감 링이 궤도와 한 규칙으로 나온다.
    private var header: some View {
        HStack(alignment: .top, spacing: metrics.sectionGap) {
            PlanetView(planet: planet, diameter: planetDiameter,
                       isPending: model.pendingTransitions[planet.id] != nil)
                // 마감 링(`dueRing`)은 지름 밖으로 3pt 나간다. 여백이 없으면 잘린다.
                .padding(4)
                .padding(.top, metrics.tightGap)
            VStack(alignment: .leading, spacing: metrics.tightGap) {
                HStack(spacing: metrics.tightGap) {
                    Text(tierLabel)
                        .arcadeType(.readout, .xs, weight: .bold)
                        .foregroundStyle(tierColor)
                    Text("·")
                        .arcadeType(.readout, .xs)
                        .foregroundStyle(theme.inkTertiary)
                    Text(stagnationLabel)
                        .arcadeType(.readout, .xs)
                        .foregroundStyle(theme.inkTertiary)
                        .monospacedDigit()
                    Text("·")
                        .arcadeType(.readout, .xs)
                        .foregroundStyle(theme.inkTertiary)
                    Text(planet.issue.statusName)
                        .arcadeType(.readout, .xs)
                        .foregroundStyle(theme.inkSecondary)
                        .lineLimit(1)
                }
                Text(planet.issue.key)
                    .arcadeType(.readout, .m, weight: .bold)
                    .foregroundStyle(theme.inkPrimary)
                // 레인 카드는 두 줄에서 자르지만 여기는 자르지 않는다 — 카드를 연 이유가
                // 바로 잘린 제목을 읽으려는 것일 때가 많다.
                Text(planet.issue.summary)
                    .arcadeType(.prose, .s)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if dueLabel != nil || planet.sprintCarryOvers > 0 {
                    HStack(spacing: metrics.rowGap) {
                        if let dueLabel {
                            Text(dueLabel)
                                .arcadeType(.readout, .xs, weight: .bold)
                                .foregroundStyle(dueColor)
                        }
                        if planet.sprintCarryOvers > 0 {
                            // 문구는 `TicketCardView`와 같아야 한다.
                            Text("↻ 스프린트 \(planet.sprintCarryOvers)회")
                                .arcadeType(.readout, .xs)
                                .foregroundStyle(theme.inkTertiary)
                                .help(sprintTooltip)
                        }
                    }
                }
            }
            // 닫기 버튼 자리를 비워 둔다 — 제목이 길면 ✕ 밑으로 들어간다.
            .padding(.trailing, metrics.sectionGap)
        }
    }

    /// 헤더의 행성 지름. 궤도에서 가장 큰 행성보다 확실히 커야 "가까이 왔다"가 읽힌다.
    private var planetDiameter: Double { metrics.size(.ticketCardWidth) * 0.3 }

    // MARK: - Jira에 물어야 아는 것

    /// 본문과 댓글. 판단은 전부 `AppModel.detailState`에 있다 — 이 파일에는 테스트가
    /// 닿지 않으므로 무엇을 보여줄지 고르는 코드를 두지 않는다.
    ///
    /// `detailState`는 시트와 공유하는 **하나의** 슬롯이다. 다른 티켓의 상세가 들어
    /// 있으면(카드를 갈아탄 직후) 그것을 그리지 않고 수신 중으로 본다 — 다른 티켓의
    /// 본문이 이 키 아래 잠깐이라도 뜨면 어느 쪽이 맞는지 알 수 없다.
    @ViewBuilder
    private var remote: some View {
        switch model.detailState {
        case .loaded(let detail) where detail.key == planet.id:
            VStack(alignment: .leading, spacing: metrics.sectionGap) {
                section("본문") {
                    if detail.description.isEmpty {
                        Text("본문이 없습니다")
                            .arcadeType(.prose, .xs)
                            .foregroundStyle(theme.inkTertiary)
                    } else {
                        RichTextView(document: detail.description)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                section(detail.comments.isEmpty ? "댓글" : "댓글 \(detail.comments.count)") {
                    if detail.comments.isEmpty {
                        Text("댓글이 없습니다")
                            .arcadeType(.prose, .xs)
                            .foregroundStyle(theme.inkTertiary)
                    } else {
                        CommentListView(comments: detail.comments)
                    }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: metrics.rowGap) {
                Text(message)
                    .arcadeType(.prose, .xs)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button("다시 받기") { Task { await model.openDetail(issueKey: planet.id) } }
                    .arcadeType(.readout, .xs)
            }
        case .idle, .loading, .loaded:
            HStack(spacing: metrics.tightGap) {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.accent)
                Text("Jira에서 본문과 댓글을 받는 중…")
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.inkTertiary)
            }
        }
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.tightGap) {
            Text(title)
                .arcadeType(.readout, .xs)
                .foregroundStyle(theme.inkTertiary)
            content()
        }
    }

    // MARK: - 출구

    private var footer: some View {
        HStack(spacing: metrics.rowGap) {
            if let site = model.siteHost,
               let url = AtlassianLinks.issue(key: planet.issue.key, site: site) {
                Link("Jira에서 열기", destination: url)
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.accent)
            }
            Spacer()
            Button("편집 열기", action: onOpenEditor)
                .arcadeType(.readout, .xs)
        }
    }

    /// 등급 라벨·색·정체일 표기·마감 표기·스프린트 툴팁은 `TicketPresentation`에
    /// 모았다 — 카드가 정본이고, 여기서는 위임만 한다(카드와 다르게 적으면 어느
    /// 쪽이 맞는지 알 수 없다).
    private var tierLabel: String { TicketPresentation.tierLabel(planet.tier) }

    private var tierColor: Color { TicketPresentation.tierColor(planet.tier, theme: theme) }

    private var stagnationLabel: String {
        TicketPresentation.stagnationLabel(days: planet.daysStagnant, isApproximate: planet.isApproximate)
    }

    private var dueLabel: String? { TicketPresentation.dueLabel(planet.dueState) }

    private var dueColor: Color { TicketPresentation.dueColor(planet.dueState, theme: theme) }

    private var sprintTooltip: String {
        TicketPresentation.sprintTooltip(first: planet.firstSprintName, latest: planet.latestSprintName)
    }
}
