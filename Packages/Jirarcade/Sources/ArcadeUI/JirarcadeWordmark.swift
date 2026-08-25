import SwiftUI
import ArcadeCore

/// 제품 이름을 그리는 유일한 곳.
///
/// 이름은 두 단어가 가운데 한 글자를 겹쳐 만들어졌다(`Wordmark` 참고). 그 경첩 글자만
/// 강조색으로 두면 한 단어 안에서 두 단어가 보인다 — 그림 마크를 따로 붙이지 않고
/// 이름 자체가 로고가 된다.
///
/// 화면마다 `Text`로 직접 쓰지 않는 이유: 그 순간 경첩 강조가 빠진 두 번째 워드마크가
/// 생기고, 같은 이름이 화면마다 다르게 보인다.
struct JirarcadeWordmark: View {
    @Environment(\.arcadeTheme) private var theme
    /// 크기 단계. 로그인 화면은 이것만 있는 화면이라 크게, 플로어 헤더는 한 단계 작게 쓴다.
    let step: LayoutTokens.TypeStep

    var body: some View {
        (
            Text(Wordmark.head).foregroundStyle(theme.inkPrimary)
            + Text(Wordmark.hinge).foregroundStyle(theme.accent)
            + Text(Wordmark.tail).foregroundStyle(theme.inkPrimary)
        )
        .arcadeType(.marquee, step)
        // 조각으로 이어 붙였다는 사실이 VoiceOver에 새지 않게 이름 하나로 읽힌다.
        .accessibilityLabel(Wordmark.full)
    }
}

/// 마퀴 간판 테두리의 전구 줄.
///
/// 헤더 아래의 구분선을 **대신한다**. 선을 하나 더 얹는 대신 이미 있던 선이 무엇인지를
/// 말하게 한 것이다 — 아케이드 간판에서 가장 물리적인 특징이 테두리를 따라 박힌 전구다.
struct MarqueeBulbRail: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics

    /// 전구 지름. 절반 크기로 그렸더니 전구가 아니라 점선 구분선으로 읽혔다 —
    /// 이 줄은 선을 대신하는 것이 아니라 그 선이 **무엇인지** 말해야 하므로,
    /// 간격 대비 알아볼 수 있는 크기가 필요하다.
    private var diameter: CGFloat { metrics.tightGap }

    var body: some View {
        GeometryReader { proxy in
            // 폭에 맞춰 개수를 정한다. 개수를 고정하면 창을 넓혔을 때 전구 간격만
            // 벌어져 간판이 아니라 흩어진 점으로 보인다.
            let pitch = metrics.sectionGap
            let count = max(Int(proxy.size.width / pitch), 2)
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { _ in
                    Circle()
                        .fill(theme.accent)
                        .frame(width: diameter, height: diameter)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: diameter)
        }
        // GeometryReader는 주어진 공간을 다 채우므로 높이를 밖에서 묶는다.
        .frame(height: diameter)
        // 켜져 있되 눈을 찌르지 않는 밝기. 이 줄은 헤더를 읽는 데 방해가 되면 안 된다.
        .opacity(0.55)
        .accessibilityHidden(true)
    }
}
