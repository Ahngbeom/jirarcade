import Testing
@testable import ArcadeCore

// MARK: - 밴드

/// 세 밴드가 본체 높이를 남김없이 나눈다. 합이 1을 넘으면 화면이 본체 밖으로
/// 삐져나가고, 모자라면 바닥에 설명할 수 없는 틈이 생긴다.
@Test func theCabinetBandsFillExactlyOne() {
    let sum = IconGeometry.Band.allCases.reduce(0) { $0 + IconGeometry.heightFraction($1) }
    #expect(abs(sum - 1) < 1e-9, "밴드 합이 1이 아니다: \(sum)")
}

/// 밴드는 위에서 아래로 이어 붙는다 — 앞 밴드의 끝이 다음 밴드의 시작이다.
@Test func theBandsStackWithoutGapsOrOverlap() {
    var expected = 0.0
    for band in IconGeometry.Band.allCases {
        #expect(abs(IconGeometry.startFraction(band) - expected) < 1e-9,
                "\(band)의 시작이 어긋났다")
        expected += IconGeometry.heightFraction(band)
    }
    #expect(abs(expected - 1) < 1e-9)
}

/// `allCases`는 위에서 아래 순서다. 위의 두 검사가 전부 이 순서에 기대고 있으므로,
/// 선언 순서가 바뀌면 그 검사들이 조용히 무의미해진다.
@Test func theBandsAreOrderedTopToBottom() {
    #expect(IconGeometry.Band.allCases == [.marquee, .bezel, .screen])
}

// MARK: - 판 위의 캐비닛

/// 본체와 조작판 **둘 다** 플레이트 안에 사방으로 여백을 남기고 들어간다.
/// 조작판이 더 넓으므로 본체만 검사하면 삐져나간 것을 놓친다.
@Test func everyPartSitsInsideThePlateWithMarginOnEverySide() {
    for part in [IconGeometry.body, IconGeometry.controlDeck] {
        #expect(part.x > 0)
        #expect(part.y > 0)
        #expect(part.x + part.width < 1)
        #expect(part.y + part.height < 1)
    }
}

/// 조작판은 본체보다 넓다.
///
/// 이 계단 하나가 실루엣에서 "아케이드 캐비닛"을 말한다. 같아지는 순간 아이콘은
/// 화면 달린 기기로 읽히고, 그건 어느 앱의 아이콘이어도 이상하지 않다.
@Test func theControlDeckProtrudesBeyondTheBody() {
    #expect(IconGeometry.controlDeck.width > IconGeometry.body.width)
}

/// 조작판은 본체 바로 아래에 붙는다 — 틈이 생기면 두 조각이 떠 보인다.
@Test func theControlDeckMeetsTheBottomOfTheBody() {
    let bodyBottom = IconGeometry.body.y + IconGeometry.body.height
    #expect(abs(IconGeometry.controlDeck.y - bodyBottom) < 1e-9)
}

/// 캐비닛은 세로로 선다. 업라이트 실루엣이 "아케이드"를 말하는 유일한 장치이고,
/// 화면 안 캐비닛 카드도 같은 규칙을 받는다(`LayoutTokens`의 동명 검사).
@Test func theIconCabinetStandsTallerThanItIsWide() {
    #expect(IconGeometry.body.height > IconGeometry.body.width)
}

/// 본체와 조작판 모두 가운데 선다. 한쪽만 어긋나면 캐비닛이 기울어 보인다.
@Test func everyPartIsHorizontallyCentered() {
    for part in [IconGeometry.body, IconGeometry.controlDeck] {
        #expect(abs(part.x - (1 - part.x - part.width)) < 1e-9)
    }
}

// MARK: - Dock에서 보이는가

/// amber가 플레이트의 3할 이상을 덮는다.
///
/// 어두운 배경화면 위에서 어두운 아이콘은 구멍처럼 보인다. 마퀴 밴드와 스크린이
/// 이 앱의 유일한 밝은 면이므로, 그 둘의 넓이가 Dock에서의 존재감을 정한다.
@Test func theAccentCoversEnoughOfThePlateToReadInTheDock() {
    let coverage = IconGeometry.accentCoverage
    #expect(coverage > 0.30, "amber 면적이 \(coverage)로 너무 작다 — 어두운 배경에서 묻힌다")
}

/// 화면은 본체 좌우에서 물러난다 — 물러나지 않으면 간판과 한 덩어리로 뭉친다.
@Test func theScreenIsInsetFromTheBodySides() {
    #expect(IconGeometry.screenInsetRatio > 0)
    // 양쪽을 합쳐도 본체 폭의 절반을 넘지 않는다. 넘으면 화면이 사라진다.
    #expect(IconGeometry.screenInsetRatio * 2 < 0.5)
}

// MARK: - 크기별 단순화

/// 작은 크기에서 요소를 빼는 순서가 정해져 있다. 조작판 버튼이 경첩 글자보다
/// 먼저 나타나면, 글자 없는 캐비닛에 버튼만 찍힌 알아볼 수 없는 그림이 된다.
@Test func detailAppearsInOrderOfImportance() {
    #expect(IconGeometry.hingeLetterMinimumPixelSize
            < IconGeometry.controlDetailMinimumPixelSize)
}

/// 임계값은 경계에서 정확해야 한다. `.iconset`의 크기가 16·32·64·128·256·512·1024로
/// 띄엄띄엄이라, 하나 어긋나면 한 단계가 통째로 잘못 그려진다.
@Test func theDetailThresholdsAreExactAtTheirBoundaries() {
    let hinge = IconGeometry.hingeLetterMinimumPixelSize
    #expect(!IconGeometry.showsHingeLetter(atPixelSize: hinge - 1))
    #expect(IconGeometry.showsHingeLetter(atPixelSize: hinge))

    let detail = IconGeometry.controlDetailMinimumPixelSize
    #expect(!IconGeometry.showsControlDetails(atPixelSize: detail - 1))
    #expect(IconGeometry.showsControlDetails(atPixelSize: detail))
}

/// 가장 작은 장에는 실루엣만 남고, 가장 큰 장에는 전부 나온다.
@Test func theSmallestSlotIsBareAndTheLargestIsComplete() {
    #expect(!IconGeometry.showsHingeLetter(atPixelSize: 16))
    #expect(!IconGeometry.showsFaceBands(atPixelSize: 16))
    #expect(!IconGeometry.showsControlDetails(atPixelSize: 16))
    #expect(IconGeometry.showsHingeLetter(atPixelSize: 1024))
    #expect(IconGeometry.showsFaceBands(atPixelSize: 1024))
    #expect(IconGeometry.showsControlDetails(atPixelSize: 1024))
}

/// 글자와 얼굴 구조는 같은 크기에서 함께 나타나고 함께 사라진다.
///
/// 갈라지면 둘 중 하나가 어중간하게 남는다 — 구조 없는 글자는 amber 판 위의 얼룩이고,
/// 글자 없는 구조는 정체를 알 수 없는 줄무늬다.
@Test func theLetterAndTheFaceStructureAppearTogether() {
    for size in [16, 32, 63, 64, 128, 1024] {
        #expect(IconGeometry.showsHingeLetter(atPixelSize: size)
                == IconGeometry.showsFaceBands(atPixelSize: size),
                "\(size)px에서 글자와 얼굴 구조가 갈렸다")
    }
}

// MARK: - iconset 슬롯

/// `iconutil`은 열 장을 정확한 이름으로 요구한다. 하나라도 빠지거나 이름이 틀리면
/// 변환이 실패하거나, 더 나쁘게는 그 크기만 흐릿하게 보간된 아이콘이 나온다.
@Test func theIconsetHasTheTenSlotsMacOSRequires() {
    let slots = IconGeometry.slots
    #expect(slots.count == 10)
    #expect(Set(slots.map(\.fileName)).count == 10, "파일 이름이 겹친다")
    for slot in slots {
        #expect(slot.pixelSize == slot.baseSize * slot.scale)
        let suffix = slot.scale == 1 ? "" : "@\(slot.scale)x"
        #expect(slot.fileName == "icon_\(slot.baseSize)x\(slot.baseSize)\(suffix).png")
    }
}

/// 실제로 그려야 하는 픽셀 크기는 일곱 가지다 — 32·128·256·512는 두 슬롯이 공유한다.
/// 렌더러가 크기별로 캐시할 수 있다는 사실을 여기에 고정한다.
@Test func theSlotsCoverSevenDistinctPixelSizes() {
    #expect(Set(IconGeometry.slots.map(\.pixelSize)) == [16, 32, 64, 128, 256, 512, 1024])
}

// MARK: - 캔버스

/// 아트워크는 캔버스를 꽉 채우지 않는다. macOS는 남은 테두리에 그림자를 얹는다.
@Test func thePlateLeavesRoomForTheSystemShadow() {
    #expect(IconGeometry.plate < IconGeometry.canvas)
    let inset = (IconGeometry.canvas - IconGeometry.plate) / 2
    #expect(inset > 0)
}

/// 조작판 버튼은 조작판 폭 안에 들어간다.
@Test func theControlButtonsFitInsideTheCabinet() {
    let radius = IconGeometry.controlButtonDiameterRatio / 2
    for centerX in IconGeometry.controlButtonCenterXs {
        #expect(centerX - radius > 0)
        #expect(centerX + radius < 1)
    }
}
