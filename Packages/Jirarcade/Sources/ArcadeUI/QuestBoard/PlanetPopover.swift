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

    private var tierLabel: String {
        switch planet.tier {
        case .fresh: "·"
        case .stale: "STALE"
        case .boss:  "BOSS"
        case .raid:  "RAID"
        }
    }

    private var tierColor: Color {
        switch planet.tier {
        case .fresh: theme.line
        case .stale: theme.accent
        case .boss, .raid: theme.boss
        }
    }

    /// 관측 이력이 없는 티켓의 정체일을 확정처럼 보여주면 "관측한 것만 안다"는
    /// 이 앱의 원칙이 화면에서 깨진다. 카드와 같은 규칙이다.
    private var stagnationLabel: String {
        (planet.isApproximate ? "~" : "") + "\(planet.daysStagnant)d"
    }

    private var dueLabel: String? {
        switch planet.dueState {
        case .none: nil
        case .overdue(let days): "\(days)일 지남"
        case .dueIn(let days): days == 0 ? "오늘 마감" : "D-\(days)"
        }
    }

    /// 강조 기준은 뷰가 정한다(`ArcadeCore`는 사실만 담는다). D-3 이내부터 눈에 띄게 한다.
    private var dueColor: Color {
        switch planet.dueState {
        case .none:              theme.inkTertiary
        case .overdue:           theme.danger
        case .dueIn(let days):   days <= 3 ? theme.accent : theme.inkTertiary
        }
    }

    private var sprintTooltip: String {
        guard let first = planet.firstSprintName, let latest = planet.latestSprintName
        else { return "" }
        return first == latest ? first : "\(first) → \(latest)"
    }
}
