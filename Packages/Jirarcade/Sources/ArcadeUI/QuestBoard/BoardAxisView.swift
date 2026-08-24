import SwiftUI
import ArcadeCore

/// 정체 시간축의 눈금선과 라벨.
///
/// 눈금은 `RuleSet`의 등급 경계값이다. boss 경계부터 선을 굵게 해 "여기부터는
/// 다른 구역"임을 색을 더 쓰지 않고 말한다.
struct BoardAxisView: View {
    @Environment(\.arcadeTheme) private var theme
    let ticks: [AxisTick]
    let metrics: BoardMetrics
    /// boss 경계의 인덱스. 이 인덱스부터 선이 굵어진다.
    private var emphasisIndex: Int { max(ticks.count - 2, 0) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { index, tick in
                VStack(alignment: .leading, spacing: 2) {
                    Rectangle()
                        .fill(theme.line)
                        .frame(width: index >= emphasisIndex ? 2 : 1)
                        .frame(maxHeight: .infinity)
                    Text(tick.isTerminal ? "\(tick.days)d+" : "\(tick.days)d")
                        .arcadeType(.readout, .xs)
                        .foregroundStyle(theme.inkTertiary)
                        .fixedSize()
                }
                // 눈금선은 카드 왼쪽 모서리 기준이 아니라 축 전체 기준이다.
                .offset(x: tick.position * metrics.usableWidth)
            }
        }
    }
}
