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
    /// 활자 스케일. 치수를 나르는 `metrics`(BoardMetrics)와 역할이 달라 이름을 가른다.
    @Environment(\.arcadeMetrics) private var density
    let slot: BoardSlot
    let metrics: BoardMetrics
    let model: AppModel
    let pending: PendingTransition?
    let failure: String?
    let onOpenDetail: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.cardLineGap) {
            HStack(spacing: density.tightGap) {
                Text(tierLabel)
                    .arcadeType(.readout, .xs, weight: .bold)
                    .foregroundStyle(tierColor)
                Spacer()
                // 새 줄을 만들지 않는다 — 카드는 이미 마감일과 이월이 함께 뜨면 요약이
                // 한 줄로 접히는 예산이다. 그리고 이 값이 수식하는 대상이 바로 옆의
                // 정체일이라, 같은 줄에 있어야 "이 18일은 3번 돌아온 뒤의 18일"로 읽힌다.
                if slot.revisits > 0 {
                    Text("⇄\(slot.revisits)")
                        .arcadeType(.readout, .xs)
                        .foregroundStyle(theme.inkTertiary)
                        .monospacedDigit()
                }
                Text(stagnationLabel)
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.inkTertiary)
                    .monospacedDigit()
            }
            // 카드 전체가 아니라 키만 탭 대상이다. 카드에는 상태 옮기기 메뉴와
            // 취소·닫기 버튼이 있어, 전체를 제스처로 덮으면 그 클릭을 가로챈다.
            Button { onOpenDetail(slot.issue.key) } label: {
                Text(slot.issue.key)
                    .arcadeType(.readout, .s, weight: .bold)
                    .foregroundStyle(theme.inkPrimary)
            }
            .buttonStyle(.plain)
            Text(slot.issue.summary)
                .arcadeType(.prose, .xs)
                .foregroundStyle(theme.inkSecondary)
                .lineLimit(2)
            // 실패 블록이 뜨는 동안은 마감일 줄을 감춘다 — 카드를 키우는 대신 이렇게 하는
            // 이유: 레인 높이는 `rowCount × cardHeight`라서, 카드를 키우면 실패가 없는
            // 보통 상태의 모든 레인도 함께 늘어난다. 실패는 지금 당장 조치가 필요한
            // 정보라 그 몇 초 동안은 마감일보다 우선한다 — 실패를 닫으면(취소하거나
            // dismissTransitionFailure) 마감일이 그대로 돌아온다.
            if let due = dueLabel, !showsFailureBlock {
                Text(due)
                    .arcadeType(.readout, .xs, weight: .bold)
                    .foregroundStyle(dueColor)
            }
            // 이월은 실패 블록이 없을 때만 그린다. 실패 블록은 2줄 메시지에 링크 줄까지
            // 붙어 35pt를 쓰므로, 이월 줄을 더하면 compact의 104pt 콘텐츠 박스를 106pt로 넘긴다.
            // 대기 중에는 숨기지 않는다 — 대기 줄은 한 줄(11pt)이라 이월을 같이 그려도
            // 96pt로 8pt가 남고, 이는 메뉴가 뜨는 보통 상태보다 오히려 여유가 크다.
            // 마감일 줄(바로 위)과 같은 술어로 gate한다 — "실패 블록이 떠 있는가"를 두
            // 가지 스펠링으로 묻지 않게, 그 판정은 `showsFailureBlock` 하나뿐이다.
            if slot.sprintCarryOvers > 0, !showsFailureBlock {
                Text("↻ 스프린트 \(slot.sprintCarryOvers)회")
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.inkTertiary)
                    .help(sprintTooltip)
            }
            if let pending {
                // 남은 시간과 대상 상태·취소를 한 줄에 묶는다 — 별도 줄을 더하면(header
                // + key + summary×2 + due + pending행 + 새 줄) 가장 빠듯한 밀도의
                // `cardHeight`에서 여유가 0pt가 된다. 같은 줄에 붙이는 쪽이 실패 블록과
                // 같은 예산 안에서 안전하게 들어간다. 카드가 커지면 글자도 함께 커지므로
                // 이 예산은 밀도가 올라가도 넉넉해지지 않는다 — 줄 수를 늘리지 않는다.
                HStack(spacing: density.tightGap) {
                    Text("→ \(pending.toStatusName)")
                        .arcadeType(.readout, .xs, weight: .bold)
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                    // 뷰가 스스로 현재 시각을 만들지 않는다 — `TimelineView`가 매초
                    // 건네는 `context.date`로만 남은 시간을 계산한다. 이 카운트다운 하나만
                    // 매초 다시 그려지고, 상위(`BoardLaneView`·`QuestBoardView`)는
                    // 영향받지 않는다 — `TimelineView`의 무효화는 그 서브트리에 갇힌다.
                    TimelineView(.periodic(from: pending.firesAt, by: 1)) { context in
                        Text(countdownLabel(firesAt: pending.firesAt, now: context.date))
                    }
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.inkTertiary)
                    .monospacedDigit()
                    Spacer()
                    Button("취소") { model.cancelPendingTransition(issueKey: slot.issue.key) }
                        .arcadeType(.readout, .xs)
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.danger)
                }
            } else if let failure {
                // Jira가 준 사유는 담지 않는다(AppModel.transitionFailureMessage 참고).
                // 대신 그 정보를 채울 수 있는 곳으로 보낸다.
                VStack(alignment: .leading, spacing: metrics.cardLineGap) {
                    Text(failure)
                        .arcadeType(.prose, .xs)
                        .foregroundStyle(theme.danger)
                        .lineLimit(2)
                    // "Jira에서 열기"와 "닫기"를 한 줄에 묶는다 — 실패 블록에 새 줄을
                    // 더하지 않는 이유는 위 pending 블록의 카운트다운이 이미 카드의
                    // 여유를 다 썼기 때문이다(아래 예산 계산 참고). 닫기 버튼은
                    // `jiraURL`이 없을 때도(siteHost를 아직 못 받았을 때) 항상 보여야
                    // 한다 — 그게 없으면 실패한 카드가 세션 내내 메뉴를 다시 열
                    // 방법이 없다(최종 전체 브랜치 리뷰 Finding 2).
                    HStack(spacing: density.tightGap) {
                        if let url = jiraURL {
                            Link("Jira에서 열기", destination: url)
                                .arcadeType(.readout, .xs)
                                .foregroundStyle(theme.accent)
                        }
                        Spacer()
                        Button("닫기") { model.dismissTransitionFailure(issueKey: slot.issue.key) }
                            .arcadeType(.readout, .xs)
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.inkTertiary)
                    }
                }
            } else {
                transitionMenu
            }
            Spacer(minLength: 0)
        }
        .padding(metrics.cardPadding)
        .frame(width: metrics.cardWidth, height: metrics.cardHeight, alignment: .topLeading)
        .background(slot.tier == .raid ? theme.boss.opacity(0.18) : theme.surfaceRaised)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(tierColor, lineWidth: slot.tier >= .boss ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(cardTooltip)
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
                        Button(transition.menuLabel) {
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
                .arcadeType(.readout, .xs)
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

    /// 카드 툴팁. 왕복과 추정을 **둘 다** 말할 수 있어야 하므로 한 문장으로 고정하지 않는다.
    private var cardTooltip: String {
        var parts: [String] = []
        if slot.revisits > 0 {
            parts.append("이미 거쳐 간 상태로 \(slot.revisits)번 돌아왔습니다")
        }
        if slot.isApproximate {
            parts.append("관측 이력이 없어 마지막 갱신 시각으로 추정한 정체일입니다")
        }
        return parts.isEmpty ? slot.issue.summary : parts.joined(separator: "\n")
    }

    /// 대기 중인 전이가 실행되기까지 남은 시간을 카드 문구로 만든다. 초 단위를 올림해
    /// "0s"가 뜨는 시간이 실제로 타이머가 발사되는 순간과 거의 맞도록 한다(내림이면
    /// 발사 몇백ms 전부터 "0s"가 떠서 이미 끝난 것처럼 보인다). 지난 시각(음수)은
    /// `firesAt`을 계산에 쓴 창이 지났을 뿐 아직 요청이 실제로 나가지 않은 짧은
    /// 틈에서 나올 수 있어 0으로 클램프한다 — 음수를 그대로 보여주면 혼란스럽다.
    private func countdownLabel(firesAt: Date, now: Date) -> String {
        let remaining = max(0, firesAt.timeIntervalSince(now))
        return "\(Int(remaining.rounded(.up)))s"
    }

    /// 대기(`pending`)가 있으면 항상 대기 배너가 우선이라 실패 블록은 뜨지 않는다
    /// (`AppModel`이 요청 시점에 `transitionFailures`를 지우므로 둘은 원래도 동시에
    /// 채워지지 않는다) — 그래도 뷰가 스스로 판정하도록 조건을 명시한다.
    ///
    /// 마감일 줄과 이월 줄 둘 다 "실패 블록이 떠 있는가"를 이 값 하나로 gate한다 —
    /// 각자 `failure == nil`을 따로 쓰면 `pending`과 `failure`가 함께 채워지는(지금은
    /// `AppModel`이 만들지 않는) 상태에서 둘이 다른 답을 낸다.
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

    /// `ArcadeCore`는 이름 둘을 사실로만 담는다. 문장은 여기서 만든다 —
    /// `DueState`·`HygieneNextStep`과 같은 경계다.
    private var sprintTooltip: String {
        guard let first = slot.firstSprintName, let latest = slot.latestSprintName
        else { return "" }
        return first == latest ? first : "\(first) → \(latest)"
    }
}
