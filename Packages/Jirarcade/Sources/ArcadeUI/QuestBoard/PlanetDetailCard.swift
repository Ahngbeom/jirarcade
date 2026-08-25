import SwiftUI
import ArcadeCore

/// 행성을 눌렀을 때 궤도 위에 뜨는 읽기 전용 상세.
///
/// `TicketCardView`를 재사용하지 않는 이유는 그 뷰가 상태 옮기기 메뉴와 5초 실행 취소
/// UI를 품고 있기 때문이다 — 궤도는 보는 화면이고 전이는 레인에서 한다.
/// 대신 표기는 `TicketPresentation`을 함께 거쳐 카드와 어긋나지 않는다.
///
/// 팝오버가 아니라 같은 뷰 트리 안의 카드인 이유: macOS 팝오버는 별도 윈도우로 떠서
/// 앱 창 바깥으로 나간다.
struct PlanetDetailCard: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
    let planet: OrbitPlanet
    let siteHost: String?
    /// 닫기. 바깥 탭과 같은 일을 하지만 버튼이 있어야 키보드로도 닿는다.
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowGap) {
            HStack(spacing: metrics.tightGap) {
                Text(tierLabel)
                    .arcadeType(.readout, .xs, weight: .bold)
                    .foregroundStyle(tierColor)
                Spacer()
                Text(stagnationLabel)
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.inkTertiary)
                    .monospacedDigit()
            }
            Text(planet.issue.key)
                .arcadeType(.readout, .s, weight: .bold)
                .foregroundStyle(theme.inkPrimary)
            Text(planet.issue.summary)
                .arcadeType(.prose, .xs)
                .foregroundStyle(theme.inkSecondary)
                .lineLimit(3)
            if let dueLabel {
                Text(dueLabel)
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(dueColor)
            }
            if planet.sprintCarryOvers > 0 {
                // 문구는 `TicketCardView`와 같아야 한다.
                Text("↻ 스프린트 \(planet.sprintCarryOvers)회")
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.inkTertiary)
                    .help(sprintTooltip)
            }
            if let site = siteHost, let url = AtlassianLinks.issue(key: planet.issue.key, site: site) {
                Link("Jira에서 열기", destination: url)
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(metrics.sectionGap)
        .frame(width: metrics.size(.ticketCardWidth) * 1.35, alignment: .leading)
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

    /// 등급 라벨·색·정체일 표기·마감 표기·스프린트 툴팁은 `TicketPresentation`에
    /// 모았다 — 카드가 정본이고, 팝오버는 위임만 한다(카드와 다르게 적으면 어느
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
