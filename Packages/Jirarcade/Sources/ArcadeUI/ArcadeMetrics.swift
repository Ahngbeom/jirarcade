import SwiftUI
import ArcadeCore

/// 레이아웃 토큰을 SwiftUI 값으로 옮긴 것.
///
/// 숫자와 밀도 판정은 `LayoutTokens`에만 있고, 여기서는 변환만 한다 —
/// `PaletteTokens` → `ArcadeTheme`와 같은 경계다.
public struct ArcadeMetrics: Sendable, Equatable {
    public let density: LayoutTokens.Density

    /// 창 폭에서 만든다. 폭 하나로만 정하는 이유: 이 앱이 넓은 화면에서 잃는 것은
    /// 세로가 아니라 가로다(보드 축, 캐비닛 행). 높이까지 보면 세로로 짧은 창에서
    /// 밀도가 떨어져 글자만 작아지고 정작 문제인 가로는 그대로 남는다.
    public static func make(forWidth width: Double) -> ArcadeMetrics {
        ArcadeMetrics(density: LayoutTokens.density(forWidth: width))
    }

    public func font(
        _ role: LayoutTokens.TypeRole,
        _ step: LayoutTokens.TypeStep,
        weight: Font.Weight? = nil
    ) -> Font {
        .system(
            size: LayoutTokens.fontSize(role, step, in: density),
            weight: weight ?? Self.defaultWeight(role),
            design: Self.design(role)
        )
    }

    public func tracking(
        _ role: LayoutTokens.TypeRole, _ step: LayoutTokens.TypeStep
    ) -> CGFloat {
        LayoutTokens.tracking(role, step, in: density)
    }

    public func space(_ token: LayoutTokens.SpaceToken) -> CGFloat {
        LayoutTokens.space(token, in: density)
    }

    public func size(_ token: LayoutTokens.SizeToken) -> CGFloat {
        LayoutTokens.size(token, in: density)
    }

    /// 자주 쓰는 여백은 이름으로 꺼낸다 — 호출부가 `metrics.space(.gutter)`보다
    /// 짧아져 레이아웃 코드가 읽힌다.
    public var gutter: CGFloat { space(.gutter) }
    public var sectionGap: CGFloat { space(.sectionGap) }
    public var rowGap: CGFloat { space(.rowGap) }
    public var tightGap: CGFloat { space(.tightGap) }

    private static func design(_ role: LayoutTokens.TypeRole) -> Font.Design {
        switch role {
        case .marquee: .rounded
        case .readout: .monospaced
        case .prose:   .default
        }
    }

    /// 역할이 정하는 기본 굵기. marquee는 늘 무겁고, 나머지는 호출부가 필요할 때만
    /// 굵게 만든다.
    private static func defaultWeight(_ role: LayoutTokens.TypeRole) -> Font.Weight {
        role == .marquee ? .heavy : .regular
    }
}

/// 폰트와 자간을 함께 얹는다. 둘을 따로 쓰면 marquee의 자간을 빠뜨리기 쉽고,
/// 그러면 같은 제목이 화면마다 다르게 보인다.
private struct ArcadeTypeModifier: ViewModifier {
    @Environment(\.arcadeMetrics) private var metrics
    let role: LayoutTokens.TypeRole
    let step: LayoutTokens.TypeStep
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        content
            .font(metrics.font(role, step, weight: weight))
            .tracking(metrics.tracking(role, step))
    }
}

public extension View {
    /// 역할과 단계로 활자를 지정한다. 크기는 지금 밀도가 정한다.
    func arcadeType(
        _ role: LayoutTokens.TypeRole,
        _ step: LayoutTokens.TypeStep,
        weight: Font.Weight? = nil
    ) -> some View {
        modifier(ArcadeTypeModifier(role: role, step: step, weight: weight))
    }
}
