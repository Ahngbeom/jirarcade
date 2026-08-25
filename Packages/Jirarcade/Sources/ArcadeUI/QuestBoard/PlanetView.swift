import SwiftUI
import ArcadeCore

/// 궤도 위의 티켓 한 개.
///
/// 등급을 색에 대응시키는 방식은 `TicketCardView`와 **같아야 한다** — 두 화면이
/// 같은 티켓을 다른 색으로 그리면 어느 쪽이 맞는지 알 수 없다. raid를 boss와 색으로
/// 가르지 않고 채움으로 가르는 것도 그 파일의 판단을 그대로 따른 것이다.
struct PlanetView: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let planet: OrbitPlanet
    let diameter: Double
    /// 전이를 기다리는 중인가. 카드의 대기 표시에 대응한다.
    let isPending: Bool

    /// raid 등급의 아주 느린 맥동. 이 화면의 유일한 상시 움직임이다.
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(fill)
            .overlay(Circle().strokeBorder(tierColor, lineWidth: strokeWidth))
            .overlay(dueRing)
            .frame(width: diameter, height: diameter)
            .opacity(isPending ? 0.5 : 1)
            .scaleEffect(pulsing ? 1.12 : 1)
            .onAppear {
                guard planet.tier == .raid, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            // 행성의 뷰 정체성은 `planet.id`(티켓 키)로 유지된다. 상태를 옮기면 정체일이
            // 리셋돼 등급이 바뀌는데(raid→fresh로 내려가거나 fresh→raid로 오르거나) `.onAppear`는
            // 다시 불리지 않으므로, 내려간 행성이 계속 맥동하거나 오른 행성이 맥동을 놓친다.
            .onChange(of: planet.tier) { syncPulsing() }
            .onChange(of: reduceMotion) { syncPulsing() }
            .accessibilityLabel(accessibilityLabel)
    }

    /// 맥동을 켜고 끄는 판단을 한 곳에 모은다 — 등급 변화와 동작 줄이기 변화가
    /// 같은 규칙을 따라야 하기 때문이다.
    private func syncPulsing() {
        guard planet.tier == .raid, !reduceMotion else {
            // `withAnimation(nil)`로 즉시 꺼야 한다. 애니메이션을 걸고 끄면
            // `repeatForever`가 진행 중인 반복을 끝내고서야 멈춰 잠깐 더 뛴다.
            withAnimation(nil) { pulsing = false }
            return
        }
        guard !pulsing else { return }
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }

    /// raid만 채운다. 팔레트에 raid 전용 토큰이 없고, 있어야 할 이유도 없다 —
    /// boss와 raid를 색으로 가르면 `ContrastTests`를 통과할 색 하나가 더 필요해진다.
    private var fill: Color {
        planet.tier == .raid ? theme.boss : theme.surfaceRaised
    }

    private var strokeWidth: Double {
        planet.tier >= .boss ? 2 : 1
    }

    private var tierColor: Color {
        switch planet.tier {
        case .fresh: theme.line
        case .stale: theme.accent
        case .boss, .raid: theme.boss
        }
    }

    /// 마감 임박은 드물게 켜지는 신호이므로 상시 손잡이가 아니라 바깥 링으로 그린다.
    /// D-3을 경계로 삼는 판단은 뷰의 몫이다 — `DueState`는 사실만 담는다.
    @ViewBuilder private var dueRing: some View {
        if case .dueIn(let days) = planet.dueState, days <= 3 {
            // `TicketCardView.dueColor`가 D-3 이내를 accent로 그린다 — overdue만 danger를
            // 쓴다. 카드와 궤도가 같은 티켓을 다른 색으로 그리면 어느 쪽이 맞는지 알 수 없다.
            Circle()
                .strokeBorder(theme.accent, lineWidth: 1)
                .padding(-3)
        } else if case .overdue = planet.dueState {
            Circle()
                .strokeBorder(theme.danger, lineWidth: 2)
                .padding(-3)
        }
    }

    private var accessibilityLabel: String {
        let stagnation = (planet.isApproximate ? "약 " : "") + "\(planet.daysStagnant)일"
        return "\(planet.issue.key), \(planet.issue.summary), 정체 \(stagnation)"
    }
}
