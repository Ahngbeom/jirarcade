import Testing
@testable import ArcadeCore

/// 밀도 경계는 **창 폭**으로만 정해진다. 경계값 자체를 고정해 두는 이유: 아래 두
/// 테스트(기본 창이 wide인가, 최소 창이 compact인가)가 이 값에 얹혀 있어서,
/// 경계를 옮기면 창 크기 상수도 함께 재검토해야 한다는 사실을 실패로 알린다.
@Test func densityBoundariesAreExact() {
    #expect(LayoutTokens.density(forWidth: 1239) == .compact)
    #expect(LayoutTokens.density(forWidth: 1240) == .regular)
    #expect(LayoutTokens.density(forWidth: 1559) == .regular)
    #expect(LayoutTokens.density(forWidth: 1560) == .wide)
}

/// 폭이 0이거나 음수인 경우(레이아웃 첫 패스에서 GeometryReader가 주는 값)에도
/// 판정이 성립해야 한다. 가장 좁은 밀도로 떨어지는 것이 안전하다 — 넓은 밀도의
/// 큰 치수가 아직 크기를 모르는 컨테이너에 들어가면 첫 프레임이 잘린다.
@Test func nonPositiveWidthFallsBackToCompact() {
    #expect(LayoutTokens.density(forWidth: 0) == .compact)
    #expect(LayoutTokens.density(forWidth: -1) == .compact)
}

/// 창 크기 상수가 의도한 밀도에 실제로 떨어지는가.
///
/// 이 앱의 기본 창은 1920×1080 디스플레이를 기준으로 잡혀 있다. 그 크기가 wide로
/// 판정되지 않으면 넓은 화면용으로 설계한 치수가 한 번도 쓰이지 않고, 최소 창이
/// compact가 아니면 가장 좁은 상태에서 큰 치수가 적용돼 내용이 잘린다.
@Test func windowConstantsLandInTheIntendedDensities() {
    #expect(LayoutTokens.density(forWidth: LayoutTokens.defaultWindow.width) == .wide)
    #expect(LayoutTokens.density(forWidth: LayoutTokens.minimumWindow.width) == .compact)
    #expect(LayoutTokens.minimumWindow.width < LayoutTokens.defaultWindow.width)
    #expect(LayoutTokens.minimumWindow.height < LayoutTokens.defaultWindow.height)
}

/// 넓은 화면일수록 커진다 — 모든 타이포 토큰에서 예외 없이.
///
/// 한 토큰만 빠뜨려도 그 자리만 작게 남아 화면에서 눈에 띄는데, 밀도별 표를 눈으로
/// 훑어서는 잡히지 않는다.
@Test func everyTypeTokenGrowsWithDensity() {
    for role in LayoutTokens.TypeRole.allCases {
        for step in LayoutTokens.TypeStep.allCases {
            let compact = LayoutTokens.fontSize(role, step, in: .compact)
            let regular = LayoutTokens.fontSize(role, step, in: .regular)
            let wide = LayoutTokens.fontSize(role, step, in: .wide)
            #expect(compact < regular, "\(role)/\(step): compact(\(compact)) < regular(\(regular))")
            #expect(regular < wide, "\(role)/\(step): regular(\(regular)) < wide(\(wide))")
        }
    }
}

/// 같은 밀도 안에서 단계는 역전되지 않는다.
///
/// 동일 크기는 허용한다 — marquee는 xs·s를 쓰지 않아 m으로 접히므로 세 단계가 같다.
@Test func typeStepsNeverShrinkWithinADensity() {
    let ascending = LayoutTokens.TypeStep.allCases
    for role in LayoutTokens.TypeRole.allCases {
        for density in LayoutTokens.Density.allCases {
            let sizes = ascending.map { LayoutTokens.fontSize(role, $0, in: density) }
            #expect(sizes == sizes.sorted(),
                    "\(role)/\(density)의 단계가 역전됐다: \(sizes)")
        }
    }
}

/// marquee는 큰 제목 전용이다. xs·s를 넘겨도 m으로 접혀야 한다 — 접지 않으면
/// 호출부가 실수로 9pt짜리 rounded-heavy 제목을 만들 수 있고, 그건 어느 화면에서도
/// 의도한 적이 없는 크기다.
@Test func marqueeClampsTheSmallStepsToMedium() {
    for density in LayoutTokens.Density.allCases {
        let medium = LayoutTokens.fontSize(.marquee, .m, in: density)
        #expect(LayoutTokens.fontSize(.marquee, .xs, in: density) == medium)
        #expect(LayoutTokens.fontSize(.marquee, .s, in: density) == medium)
    }
}

/// 트래킹은 marquee에만 붙인다. 모노스페이스(readout)에 자간을 더하면 숫자 정렬이
/// 흔들려 스코어보드로서의 성질을 잃고, 문장(prose)은 기본 자간이 이미 최적이다.
@Test func onlyTheMarqueeCarriesTracking() {
    for density in LayoutTokens.Density.allCases {
        #expect(LayoutTokens.tracking(.marquee, .xl, in: density) > 0)
        #expect(LayoutTokens.tracking(.readout, .xl, in: density) == 0)
        #expect(LayoutTokens.tracking(.prose, .xl, in: density) == 0)
    }
}

/// 여백과 치수도 타이포와 같은 규칙을 받는다 — 하나라도 고정값으로 남으면
/// 넓은 화면에서 그 자리만 좁아 보인다.
@Test func everySpaceAndSizeTokenGrowsWithDensity() {
    for token in LayoutTokens.SpaceToken.allCases {
        let values = LayoutTokens.Density.allCases.map { LayoutTokens.space(token, in: $0) }
        #expect(values == values.sorted() && Set(values).count == values.count,
                "\(token)이 밀도에 따라 커지지 않는다: \(values)")
    }
    for token in LayoutTokens.SizeToken.allCases {
        let values = LayoutTokens.Density.allCases.map { LayoutTokens.size(token, in: $0) }
        #expect(values == values.sorted() && Set(values).count == values.count,
                "\(token)이 밀도에 따라 커지지 않는다: \(values)")
    }
}

/// `Density.allCases`는 좁은 것부터 넓은 것 순이어야 한다. 위의 단조 증가 검사들이
/// 전부 이 순서에 기대고 있으므로, 선언 순서가 바뀌면 그 검사들이 조용히 무의미해진다.
@Test func densityCasesAreOrderedNarrowToWide() {
    #expect(LayoutTokens.Density.allCases == [.compact, .regular, .wide])
}

/// 티켓 카드는 어느 밀도에서도 세로가 가로보다 짧다. `LanePacker`는 카드를 가로축에
/// 늘어놓고 겹치면 아래로 쌓는데, 카드가 세로로 길어지면 몇 장만 겹쳐도 레인 높이가
/// 화면을 넘어간다.
@Test func theTicketCardStaysWiderThanItIsTall() {
    for density in LayoutTokens.Density.allCases {
        let width = LayoutTokens.size(.ticketCardWidth, in: density)
        let height = LayoutTokens.size(.ticketCardHeight, in: density)
        #expect(height < width, "\(density)에서 티켓 카드가 세로로 길다: \(width)×\(height)")
    }
}

/// 기본 창 크기는 화면보다 커질 수 없다.
///
/// 1920×1080을 기준으로 잡은 값이지만 이 앱은 노트북 내장 화면(작업영역이 그보다
/// 좁다)에서도 열린다. 클램프하지 않으면 창의 아래쪽이 Dock 밑으로, 오른쪽이 화면
/// 밖으로 나가 버튼에 닿을 수 없게 된다.
@Test func theDefaultWindowNeverExceedsTheAvailableArea() {
    let narrow = LayoutTokens.WindowSize(width: 1280, height: 800)
    let fitted = LayoutTokens.fittedWindow(within: narrow)
    #expect(fitted.width == 1280)
    #expect(fitted.height == 800)

    let roomy = LayoutTokens.WindowSize(width: 1920, height: 1055)
    #expect(LayoutTokens.fittedWindow(within: roomy) == LayoutTokens.defaultWindow,
            "여유가 있으면 기본값을 그대로 쓴다")
}

/// 캐비닛은 어느 밀도에서도 세로가 가로보다 길다.
///
/// 업라이트 캐비닛의 실루엣(간판·화면·조작판이 위에서 아래로 쌓인 형태)이 이 비율에
/// 얹혀 있다. 정사각에 가까워지면 세 밴드가 납작해져 그냥 타일로 보인다.
@Test func theCabinetStandsTallerThanItIsWide() {
    for density in LayoutTokens.Density.allCases {
        let width = LayoutTokens.size(.cabinetWidth, in: density)
        let height = LayoutTokens.size(.cabinetHeight, in: density)
        #expect(height > width, "\(density)에서 캐비닛이 세로로 서지 않는다: \(width)×\(height)")
    }
}
