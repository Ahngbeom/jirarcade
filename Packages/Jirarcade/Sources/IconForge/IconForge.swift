import AppKit
import ArcadeCore

/// 앱 아이콘을 `.iconset`으로 그린다.
///
/// 판단은 전부 `IconGeometry`와 `PaletteTokens`에 있다 — 이 파일에는 좌표를 픽셀로
/// 곱하고 색을 칠하는 일만 있다. `PaletteTokens` → `ArcadeTheme`, `LayoutTokens` →
/// `ArcadeMetrics`와 같은 경계다.
///
/// 사용법: `IconForge <출력 .iconset 디렉터리>`
@main
enum IconForge {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            fail("사용법: IconForge <출력 .iconset 디렉터리>")
        }
        let output = URL(fileURLWithPath: arguments[1])

        do {
            try FileManager.default.createDirectory(
                at: output, withIntermediateDirectories: true
            )
        } catch {
            fail("출력 디렉터리를 만들 수 없습니다: \(error.localizedDescription)")
        }

        // 열 슬롯이 쓰는 픽셀 크기는 일곱 가지뿐이다(32·128·256·512는 두 슬롯이
        // 공유한다). 같은 그림을 두 번 그리지 않는다.
        var rendered: [Int: Data] = [:]
        for slot in IconGeometry.slots {
            let png: Data
            if let cached = rendered[slot.pixelSize] {
                png = cached
            } else {
                guard let fresh = render(pixelSize: slot.pixelSize) else {
                    fail("\(slot.pixelSize)px를 그리지 못했습니다")
                }
                rendered[slot.pixelSize] = fresh
                png = fresh
            }
            do {
                try png.write(to: output.appendingPathComponent(slot.fileName))
            } catch {
                fail("\(slot.fileName)을 쓰지 못했습니다: \(error.localizedDescription)")
            }
        }

        print("✓ \(IconGeometry.slots.count)장 — \(output.path)")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
        exit(2)
    }

    // MARK: - 그리기

    private static func render(pixelSize: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize, pixelsHigh: pixelSize,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(pixelSize: Double(pixelSize))
        NSGraphicsContext.current?.flushGraphics()

        return rep.representation(using: .png, properties: [:])
    }

    private static func draw(pixelSize: Double) {
        // 캔버스(1024) 안의 플레이트(824) 비율을 지금 픽셀 크기로 옮긴다.
        let plateSide = pixelSize * IconGeometry.plate / IconGeometry.canvas
        let inset = (pixelSize - plateSide) / 2

        /// 플레이트 정규화 좌표(왼쪽 위 원점)를 캔버스 픽셀 좌표(왼쪽 **아래** 원점)로.
        /// AppKit은 y가 위로 자라므로 여기서 한 번만 뒤집는다.
        func px(_ rect: IconGeometry.Rect) -> NSRect {
            NSRect(
                x: inset + rect.x * plateSide,
                y: inset + (1 - rect.y - rect.height) * plateSide,
                width: rect.width * plateSide,
                height: rect.height * plateSide
            )
        }

        drawPlate(inset: inset, side: plateSide)

        let stroke = plateSide * IconGeometry.cabinetStrokeRatio

        // 조작판을 먼저 그린다 — 본체가 그 위에 얹혀 두 조각의 이음매가 덮인다.
        let deckRect = px(IconGeometry.controlDeck)
        let deckPath = roundedPath(deckRect)
        // `line`으로 칠한다. `surfaceRaised`는 플레이트 그라데이션과 거의 같은 밝기라
        // 조작판이 그림자로만 보였고(실측), 그러면 실루엣의 계단이 사라진다.
        color("line").setFill()
        deckPath.fill()
        if IconGeometry.showsControlDetails(atPixelSize: Int(pixelSize)) {
            drawControlButtons(in: deckRect)
        }
        color("line").setStroke()
        deckPath.lineWidth = stroke
        deckPath.stroke()

        let bodyRect = px(IconGeometry.body)
        let bodyPath = roundedPath(bodyRect)
        if IconGeometry.showsFaceBands(atPixelSize: Int(pixelSize)) {
            NSGraphicsContext.saveGraphicsState()
            bodyPath.addClip()
            // 화면이 물러난 좌우에 드러날 바탕. 밴드보다 먼저 깔아야 한다.
            color("surfaceBase").setFill()
            bodyRect.fill()
            drawBands(in: bodyRect, pixelSize: pixelSize)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // 작은 장에서는 얼굴을 한 덩어리로 칠한다. 구조를 그리면 서브픽셀 틈이
            // amber 위에 흙탕물 같은 띠를 남긴다.
            color("accent").setFill()
            bodyPath.fill()
        }

        color("line").setStroke()
        bodyPath.lineWidth = stroke
        bodyPath.stroke()
    }

    private static func roundedPath(_ rect: NSRect) -> NSBezierPath {
        let radius = rect.width * IconGeometry.cabinetCornerRatio
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    private static func drawPlate(inset: Double, side: Double) {
        let rect = NSRect(x: inset, y: inset, width: side, height: side)
        let radius = side * IconGeometry.plateCornerRatio
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        // 아래에서 위로 칠하므로 시작이 `surfaceBase`(바닥), 끝이 `surfaceRaised`(천장)다.
        let gradient = NSGradient(starting: color("surfaceBase"), ending: color("surfaceRaised"))
        gradient?.draw(in: path, angle: 90)
    }

    private static func drawBands(in body: NSRect, pixelSize: Double) {
        for band in IconGeometry.Band.allCases {
            // 화면만 좌우로 물러난다. 간판은 본체 폭을 꽉 채워 두 면이 갈린다.
            let inset = band == .screen ? body.width * IconGeometry.screenInsetRatio : 0
            let bandRect = NSRect(
                x: body.minX + inset,
                // 밴드는 위에서 아래로 세지만 AppKit의 y는 아래에서 위로 자란다.
                y: body.maxY
                    - (IconGeometry.startFraction(band) + IconGeometry.heightFraction(band))
                    * body.height,
                width: body.width - inset * 2,
                height: IconGeometry.heightFraction(band) * body.height
            )
            fill(band).setFill()
            bandRect.fill()

            if band == .screen, IconGeometry.showsHingeLetter(atPixelSize: Int(pixelSize)) {
                drawHingeLetter(in: bandRect)
            }
        }
    }

    private static func fill(_ band: IconGeometry.Band) -> NSColor {
        switch band {
        case .marquee, .screen: color("accent")
        // 본체 바탕. 화면이 물러난 좌우도 이 색이 드러난다.
        case .bezel:            color("surfaceBase")
        }
    }

    /// 화면 가운데에 경첩 글자를 얹는다. 문자열은 `Wordmark`가 정한다 — 여기서
    /// `"A"`를 직접 쓰면 이름이 바뀌었을 때 아이콘만 옛 글자를 들고 남는다.
    private static func drawHingeLetter(in screen: NSRect) {
        let target = screen.height * IconGeometry.hingeLetterHeightRatio
        // 대문자 높이를 기준으로 맞춘다. 글꼴 크기로 맞추면 서체마다 실제 글자
        // 높이가 달라져 화면 안에서 뜨거나 넘친다.
        let probe = roundedHeavy(ofSize: 100)
        guard probe.capHeight > 0 else { return }
        let font = roundedHeavy(ofSize: 100 * target / probe.capHeight)

        let text = Wordmark.hinge as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color("surfaceBase"),
        ]
        let size = text.size(withAttributes: attributes)
        // `draw(at:)`의 기준점은 베이스라인이 아니라 **라인 프래그먼트의 왼쪽 아래**다.
        // 베이스라인은 그 지점에서 `descender`만큼 위에 있고(`descender`는 음수),
        // 대문자 상자를 화면 중앙에 맞추려면 베이스라인이 `midY - capHeight/2`여야 한다.
        // 부호를 뒤집어 쓰면 글자가 |descender|만큼 위로 밀려 화면 밴드를 넘는다.
        text.draw(
            at: NSPoint(
                x: screen.midX - size.width / 2,
                y: screen.midY - font.capHeight / 2 + font.descender
            ),
            withAttributes: attributes
        )
    }

    /// 조작판 버튼 두 개. 가장 큰 장에서만 나타나는 결이다 — 작은 크기에서는
    /// 얼룩이 되어 실루엣만 흐린다.
    private static func drawControlButtons(in deck: NSRect) {
        // 조작판이 `line`이 됐으므로 버튼은 그보다 어두워야 눌린 구멍으로 읽힌다.
        color("surfaceBase").setFill()
        let diameter = deck.width * IconGeometry.controlButtonDiameterRatio
        for centerX in IconGeometry.controlButtonCenterXs {
            let origin = NSPoint(
                x: deck.minX + centerX * deck.width - diameter / 2,
                y: deck.midY - diameter / 2
            )
            NSBezierPath(ovalIn: NSRect(
                origin: origin, size: NSSize(width: diameter, height: diameter)
            )).fill()
        }
    }

    // MARK: - 팔레트와 서체

    /// 색은 `PaletteTokens`에서만 온다. hex를 여기 적으면 팔레트를 고쳐도
    /// 아이콘만 옛 색으로 남는다.
    private static func color(_ token: String) -> NSColor {
        let rgb = RGB(hex: PaletteTokens.hex(token, in: .dark))
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    /// 워드마크와 같은 서체 — 화면 안의 `JIRARCADE`와 아이콘의 글자가 같아야 한다.
    private static func roundedHeavy(ofSize size: Double) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .heavy)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: size)
        else { return base }
        return rounded
    }
}
