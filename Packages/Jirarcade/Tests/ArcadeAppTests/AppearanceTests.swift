import Testing
@testable import ArcadeApp
import ArcadeCore

@Test func systemPreferenceFollowsTheHost() {
    #expect(AppearancePreference.system.resolve(systemIsDark: true) == .dark)
    #expect(AppearancePreference.system.resolve(systemIsDark: false) == .light)
}

@Test func explicitPreferenceIgnoresTheHost() {
    #expect(AppearancePreference.dark.resolve(systemIsDark: false) == .dark)
    #expect(AppearancePreference.light.resolve(systemIsDark: true) == .light)
}

@Test func preferenceRoundTripsThroughItsRawValue() {
    for pref in AppearancePreference.allCases {
        #expect(AppearancePreference(rawValue: pref.rawValue) == pref)
    }
}
