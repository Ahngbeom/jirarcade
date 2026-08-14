import ArcadeCore

/// 사용자의 외관 선택. SwiftUI 타입이 아니므로 ArcadeApp에 둔다 —
/// UserDefaults에 저장되고 ArcadeUI가 읽어 테마를 고른다.
public enum AppearancePreference: String, Sendable, CaseIterable {
    case system, light, dark

    /// 호스트의 현재 외관과 합쳐 실제 팔레트를 정한다.
    public func resolve(systemIsDark: Bool) -> PaletteTokens.Appearance {
        switch self {
        case .system: systemIsDark ? .dark : .light
        case .light:  .light
        case .dark:   .dark
        }
    }
}
