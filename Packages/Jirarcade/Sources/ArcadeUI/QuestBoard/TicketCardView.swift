import SwiftUI
import ArcadeCore
import ArcadeApp
import JiraKit

/// 축 위에 놓이는 티켓 한 장.
///
/// raid를 boss와 색으로 가르지 않고 **채움**으로 가르는 이유: 팔레트는 대비 테스트로
/// 확정돼 있고 raid 전용 토큰이 없다. `RootView.warningBanner`가 같은 판단을 이미 했다.
struct TicketCardView: View {
    @Environment(\.arcadeTheme) private var theme
    let slot: BoardSlot
    let metrics: BoardMetrics
    let model: AppModel
    let pending: PendingTransition?
    let failure: String?

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
            // 실패 블록이 뜨는 동안은 마감일 줄을 감춘다 — 카드를 키우는 대신 이렇게 하는
            // 이유: 레인 높이는 `rowCount × cardHeight`라서, 카드를 키우면 실패가 없는
            // 보통 상태의 모든 레인도 함께 늘어난다. 실패는 지금 당장 조치가 필요한
            // 정보라 그 몇 초 동안은 마감일보다 우선한다 — 실패를 닫으면(취소하거나
            // dismissTransitionFailure) 마감일이 그대로 돌아온다.
            if let due = dueLabel, !showsFailureBlock {
                Text(due)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(dueColor)
            }
            if let pending {
                HStack(spacing: 4) {
                    Text("→ \(pending.toStatusName)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                    Spacer()
                    Button("취소") { model.cancelPendingTransition(issueKey: slot.issue.key) }
                        .font(.system(size: 9, design: .monospaced))
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.danger)
                }
            } else if let failure {
                // Jira가 준 사유는 담지 않는다(AppModel.transitionFailureMessage 참고).
                // 대신 그 정보를 채울 수 있는 곳으로 보낸다.
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure)
                        .font(.system(size: 9))
                        .foregroundStyle(theme.danger)
                        .lineLimit(2)
                    if let url = jiraURL {
                        Link("Jira에서 열기", destination: url)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(theme.accent)
                    }
                }
            } else {
                transitionMenu
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

    /// 전이 후보는 **메뉴를 열 때** 받아온다. 캐싱하지 않는 이유: 관리자가 워크플로를
    /// 바꾸면 캐시된 전이 ID는 즉시 틀린 값이 된다(v0.1 스펙 §8.5).
    @State private var transitions: [JiraTransition] = []
    @State private var isLoadingTransitions = false

    /// `.onTapGesture`를 `Menu`의 라벨에 얹으면 그 탭이 메뉴를 여는 제스처를 가로챌 수
    /// 있어(macOS·iOS 모두) 메뉴가 아예 열리지 않거나, 열리더라도 내용을 채우는 핸들러가
    /// 불리지 않을 수 있다. 대신 `Menu`의 `content` 클로저는 열릴 때마다(정적 `List`와
    /// 달리) 새로 평가된다는 성질을 쓴다 — 그 안에 있는 뷰의 `.onAppear`는 메뉴가 실제로
    /// 열려 항목이 화면에 나타나는 시점에 불리므로, 카드가 처음 그려질 때가 아니라
    /// **사용자가 메뉴를 열 때마다** 새로 받아온다.
    private var transitionMenu: some View {
        Menu {
            Group {
                if isLoadingTransitions {
                    Text("불러오는 중…")
                } else if transitions.isEmpty {
                    Text("옮길 수 있는 상태가 없습니다")
                } else {
                    ForEach(transitions, id: \.id) { transition in
                        Button(transition.name) {
                            model.requestTransition(issueKey: slot.issue.key, transition: transition)
                        }
                    }
                }
            }
            .onAppear { loadTransitions() }
            if let url = jiraURL {
                Divider()
                Link("Jira에서 열기", destination: url)
            }
        } label: {
            Text("상태 옮기기")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(theme.inkTertiary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var jiraURL: URL? {
        guard let site = model.siteHost else { return nil }
        return AtlassianLinks.issue(key: slot.issue.key, site: site)
    }

    private func loadTransitions() {
        guard !isLoadingTransitions else { return }
        isLoadingTransitions = true
        Task {
            transitions = (try? await model.availableTransitions(for: slot.issue.key)) ?? []
            isLoadingTransitions = false
        }
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

    /// 대기(`pending`)가 있으면 항상 대기 배너가 우선이라 실패 블록은 뜨지 않는다
    /// (`AppModel`이 요청 시점에 `transitionFailures`를 지우므로 둘은 원래도 동시에
    /// 채워지지 않는다) — 그래도 뷰가 스스로 판정하도록 조건을 명시한다.
    private var showsFailureBlock: Bool { pending == nil && failure != nil }

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
