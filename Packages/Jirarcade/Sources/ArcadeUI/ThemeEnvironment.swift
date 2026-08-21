import SwiftUI
import ArcadeCore
import ArcadeApp

private struct ArcadeThemeKey: EnvironmentKey {
    static let defaultValue = ArcadeTheme.make(.dark)
}

public extension EnvironmentValues {
    var arcadeTheme: ArcadeTheme {
        get { self[ArcadeThemeKey.self] }
        set { self[ArcadeThemeKey.self] = newValue }
    }
}

public extension View {
    /// 외관 설정과 호스트의 현재 외관을 합쳐 테마를 주입한다.
    func arcadeTheme(_ preference: AppearancePreference, systemIsDark: Bool) -> some View {
        environment(\.arcadeTheme, .make(preference.resolve(systemIsDark: systemIsDark)))
    }
}
