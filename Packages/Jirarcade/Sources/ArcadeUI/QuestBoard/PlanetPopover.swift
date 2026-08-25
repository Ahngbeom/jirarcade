import SwiftUI
import ArcadeCore

/// 행성을 눌렀을 때 뜨는 읽기 전용 요약.
///
/// `TicketCardView`를 재사용하지 않는 이유는 그 뷰가 상태 옮기기 메뉴와 5초 실행 취소
/// UI를 품고 있기 때문이다 — 궤도는 보는 화면이고 전이는 레인에서 한다(스펙 §12).
/// 대신 표기는 카드와 맞춘다.
struct PlanetPopover: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
    let planet: OrbitPlanet
    let siteHost: String?

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
        .frame(width: metrics.size(.ticketCardWidth))
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
