import Foundation

public struct RGB: Sendable, Equatable {
    public let red: Double, green: Double, blue: Double

    public init(hex: String) {
        var text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        // 파싱 실패를 검정으로 떨어뜨리면 안 된다 — 라이트 테마의 어두운 토큰이 오타로
        // 검정이 되면 대비가 최댓값 쪽으로 튀어 기준 미달인 색을 가짜로 통과시킨다.
        guard let value = UInt32(text, radix: 16) else {
            fatalError("잘못된 hex 색상 문자열: \(hex)")
        }
        red   = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue  = Double(value & 0xFF) / 255
    }

    /// WCAG 2.1 상대 휘도.
    public var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}

public func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
    let first = a.relativeLuminance, second = b.relativeLuminance
    let lighter = max(first, second), darker = min(first, second)
    return (lighter + 0.05) / (darker + 0.05)
}

/// 두 테마의 색 토큰. ArcadeUI가 이 값을 읽어 Color를 만든다.
/// 대비 기준을 만족하지 못하는 값은 이 파일에서 고치고 테스트로 확인한다.
public enum PaletteTokens {
    public enum Appearance: Sendable { case dark, light }

    public static let darkHex: [String: String] = [
        "surfaceBase":   "#0A0B10",
        "surfaceRaised": "#13151F",
        "line":          "#262A3A",
        "inkPrimary":    "#E8E9F1",
        "inkSecondary":  "#878CA3",
        "inkTertiary":   "#7A7F94",
        "accent":        "#FFB43C",
        "boss":          "#FF3D8A",
        "danger":        "#FF6B5E",
        "good":          "#6EE87A",
    ]

    public static let lightHex: [String: String] = [
        "surfaceBase":   "#E9E9E4",
        "surfaceRaised": "#FFFFFF",
        "line":          "#C6C6BE",
        "inkPrimary":    "#16171C",
        "inkSecondary":  "#55575F",
        "inkTertiary":   "#63655D",
        "accent":        "#8F4E00",
        "boss":          "#A8115C",
        "danger":        "#A81F14",
        "good":          "#1A6B2C",
    ]

    public static func hex(_ token: String, in appearance: Appearance) -> String {
        let table = appearance == .dark ? darkHex : lightHex
        guard let value = table[token] else {
            fatalError("정의되지 않은 색 토큰: \(token)")
        }
        return value
    }

    public static func contrastAgainstSurface(token: String, in appearance: Appearance) -> Double {
        contrastRatio(
            RGB(hex: hex(token, in: appearance)),
            RGB(hex: hex("surfaceBase", in: appearance))
        )
    }
}
