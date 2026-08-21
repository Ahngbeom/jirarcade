import SwiftUI
import ArcadeCore

/// 팔레트 토큰을 SwiftUI Color로 옮긴 것.
/// hex는 PaletteTokens에만 있고 대비 검증도 거기서 끝난다 — 여기서는 변환만 한다.
public struct ArcadeTheme: Sendable {
    /// `color(forToken:)`가 팔레트를 다시 조회할 때 쓴다.
    public let appearance: PaletteTokens.Appearance

    public let surfaceBase, surfaceRaised, line: Color
    public let inkPrimary, inkSecondary, inkTertiary: Color
    public let accent, boss, danger, good: Color

    /// 다크는 발광으로, 라이트는 잉크 밀도로 강조한다. 효과 구현은 계획 2b.
    public let usesGlow: Bool
    public let usesHalftone: Bool

    public static func make(_ appearance: PaletteTokens.Appearance) -> ArcadeTheme {
        func color(_ token: String) -> Color {
            Color(hex: PaletteTokens.hex(token, in: appearance))
        }
        return ArcadeTheme(
            appearance: appearance,
            surfaceBase: color("surfaceBase"),
            surfaceRaised: color("surfaceRaised"),
            line: color("line"),
            inkPrimary: color("inkPrimary"),
            inkSecondary: color("inkSecondary"),
            inkTertiary: color("inkTertiary"),
            accent: color("accent"),
            boss: color("boss"),
            danger: color("danger"),
            good: color("good"),
            usesGlow: appearance == .dark,
            usesHalftone: appearance == .light
        )
    }

    /// 토큰 이름으로 색을 얻는다. `Cabinet.accentToken`처럼 문자열로 색을 지정하는 곳에서 쓴다.
    /// 알 수 없는 토큰은 `PaletteTokens`가 fatalError로 잡는다 — 틀린 색이 화면에 닿는 것보다 낫다.
    public func color(forToken token: String) -> Color {
        Color(hex: PaletteTokens.hex(token, in: appearance))
    }
}

extension Color {
    /// `#RRGGBB` 문자열에서 만든다. PaletteTokens가 유효성을 이미 보장하므로
    /// 여기서 실패하면 프로그래머 오류다.
    init(hex: String) {
        let rgb = RGB(hex: hex)
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}
