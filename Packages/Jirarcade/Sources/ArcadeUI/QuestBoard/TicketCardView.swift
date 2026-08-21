import SwiftUI
import ArcadeCore

/// 축 위에 놓이는 티켓 한 장.
///
/// raid를 boss와 색으로 가르지 않고 **채움**으로 가르는 이유: 팔레트는 대비 테스트로
/// 확정돼 있고 raid 전용 토큰이 없다. `RootView.warningBanner`가 같은 판단을 이미 했다.
struct TicketCardView: View {
    @Environment(\.arcadeTheme) private var theme
    let slot: BoardSlot
    let metrics: BoardMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(tierLabel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(tierColor)
                Spacer()
                Text(stagnationLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.inkTertiary)
                    .monospacedDigit()
            }
            Text(slot.issue.key)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.inkPrimary)
            Text(slot.issue.summary)
                .font(.system(size: 10))
                .foregroundStyle(theme.inkSecondary)
                .lineLimit(2)
            if let due = dueLabel {
                Text(due)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(dueColor)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: metrics.cardWidth, height: metrics.cardHeight, alignment: .topLeading)
        .background(slot.tier == .raid ? theme.boss.opacity(0.18) : theme.surfaceRaised)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(tierColor, lineWidth: slot.tier >= .boss ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(slot.isApproximate
              ? "관측 이력이 없어 마지막 갱신 시각으로 추정한 정체일입니다"
              : slot.issue.summary)
    }

    private var tierLabel: String {
        switch slot.tier {
        case .fresh:  return "·"
        case .stale:  return "STALE"
        case .boss:   return "BOSS"
        case .raid:   return "RAID"
        }
    }

    private var tierColor: Color {
        switch slot.tier {
        case .fresh:  return theme.line
        case .stale:  return theme.accent
        case .boss, .raid: return theme.boss
        }
    }

    /// 근사값에 `~`를 붙인다. 관측 이력이 없는 티켓의 정체일을 확정처럼 보여주면
    /// "관측한 것만 안다"는 이 앱의 원칙이 화면에서 깨진다.
    private var stagnationLabel: String {
        (slot.isApproximate ? "~" : "") + "\(slot.daysStagnant)d"
    }

    private var dueLabel: String? {
        switch slot.dueState {
        case .none:                 return nil
        case .overdue(let days):    return "\(days)일 지남"
        case .dueIn(let days):      return days == 0 ? "오늘 마감" : "D-\(days)"
        }
    }

    /// 강조 기준은 뷰가 정한다(`ArcadeCore`는 사실만 담는다). D-3 이내부터 눈에 띄게 한다.
    private var dueColor: Color {
        switch slot.dueState {
        case .none:              return theme.inkTertiary
        case .overdue:           return theme.danger
        case .dueIn(let days):   return days <= 3 ? theme.accent : theme.inkTertiary
        }
    }
}
