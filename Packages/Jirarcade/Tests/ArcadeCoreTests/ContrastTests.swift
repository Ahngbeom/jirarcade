import Testing
@testable import ArcadeCore

@Test func knownContrastValuesAreComputedCorrectly() {
    let white = RGB(hex: "#FFFFFF")
    let black = RGB(hex: "#000000")
    #expect(abs(contrastRatio(white, black) - 21.0) < 0.05)
    #expect(abs(contrastRatio(white, white) - 1.0) < 0.001)
}

@Test func bothPalettesDefineTheSameTokenNames() {
    #expect(Set(PaletteTokens.darkHex.keys) == Set(PaletteTokens.lightHex.keys))
}

@Test(arguments: ["inkPrimary", "inkSecondary", "inkTertiary"])
func darkTextTokensMeetAA(token: String) {
    let ratio = PaletteTokens.contrastAgainstSurface(token: token, in: .dark)
    #expect(ratio >= 4.5, "\(token) 다크 대비 \(ratio)")
}

@Test(arguments: ["inkPrimary", "inkSecondary", "inkTertiary"])
func lightTextTokensMeetAA(token: String) {
    let ratio = PaletteTokens.contrastAgainstSurface(token: token, in: .light)
    #expect(ratio >= 4.5, "\(token) 라이트 대비 \(ratio)")
}

@Test(arguments: ["accent", "boss", "danger", "good"])
func darkAccentTokensMeetGraphicMinimum(token: String) {
    #expect(PaletteTokens.contrastAgainstSurface(token: token, in: .dark) >= 3.0)
}

@Test(arguments: ["accent", "boss", "danger", "good"])
func lightAccentTokensMeetGraphicMinimum(token: String) {
    #expect(PaletteTokens.contrastAgainstSurface(token: token, in: .light) >= 3.0)
}
