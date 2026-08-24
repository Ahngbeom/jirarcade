import Foundation

/// 앱 아이콘의 기하. 그리는 일은 `IconForge`가 하고, **무엇을 어디에** 그릴지는 여기서 정한다.
///
/// `PaletteTokens`·`LayoutTokens`·`Wordmark`와 같은 자리에 같은 이유로 있다: 판단은
/// 테스트가 있는 모듈에 두고 바깥 계층은 옮기기만 한다. 아이콘은 눈으로만 확인할 수
/// 있는 산출물이라 이 분리가 특히 중요하다 — 숫자가 여기 있으면 밴드 합이나 크기별
/// 임계값 같은 것은 눈이 아니라 테스트가 지킨다.
///
/// 좌표계는 **왼쪽 위가 원점**인 정규화 좌표(0…1)다. AppKit은 왼쪽 아래가 원점이므로
/// 뒤집는 일은 그리는 쪽이 한다.
public enum IconGeometry {
    /// 아이콘 캔버스 한 변. macOS 아이콘의 기준 크기다.
    public static let canvas: Double = 1024

    /// 캔버스 안에서 아트워크가 차지하는 정사각형 한 변.
    ///
    /// 캔버스를 꽉 채우지 않는 이유: macOS가 남은 테두리에 그림자를 얹는다.
    /// Big Sur 이후 표준 그리드가 1024 캔버스에 824 플레이트다.
    public static let plate: Double = 824

    /// 플레이트 모서리 반지름 ÷ 플레이트 한 변. macOS의 둥근 사각형 비율이다.
    public static let plateCornerRatio: Double = 185.4 / 824

    /// 플레이트 기준 정규화 사각형. 왼쪽 위가 원점이다.
    public struct Rect: Sendable, Equatable {
        public let x, y, width, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// 캐비닛 본체 — 간판과 화면이 들어간다. 사방에 여백을 남긴다: 가장자리에 닿으면
    /// 시스템 그림자와 겹쳐 실루엣이 뭉개진다.
    public static let body = Rect(x: 0.21, y: 0.09, width: 0.58, height: 0.64)

    /// 조작판 단. 본체보다 **넓어 양옆으로 튀어나온다.**
    ///
    /// 실루엣에서 "아케이드 캐비닛"을 말하는 유일한 장치다. 직사각형 하나로만 그리면
    /// 화면 달린 기기(태블릿·모니터)로 읽히고, 그건 어느 앱의 아이콘이어도 이상하지 않다.
    /// 계단 하나가 색보다 많은 일을 한다 — 16px에서도 남는다.
    public static let controlDeck = Rect(x: 0.15, y: 0.73, width: 0.70, height: 0.16)

    /// 모서리 반지름 ÷ 본체 폭. 플레이트보다 훨씬 작다 — 캐비닛은 기계이지
    /// 아이콘 판이 아니다.
    public static let cabinetCornerRatio: Double = 0.05

    /// 캐비닛 외곽선 두께 ÷ 플레이트 한 변. 조작판이 플레이트 바닥과 같은 계열이라
    /// 이 선이 없으면 아래쪽 윤곽이 사라진다.
    public static let cabinetStrokeRatio: Double = 0.006

    /// 본체 높이를 나누는 세 밴드. **위에서 아래 순서**이며, 이 순서에
    /// `startFraction(_:)`과 그 테스트가 기대고 있다.
    public enum Band: Sendable, CaseIterable, Equatable {
        /// 간판. 화면 안 캐비닛 카드의 마퀴와 같은 역할이다.
        case marquee
        /// 간판과 화면 사이의 검은 틈. 두 amber 면이 한 덩어리로 뭉치지 않게 가른다.
        case bezel
        /// 어트랙트 화면. 경첩 글자가 여기 놓인다.
        case screen
    }

    /// 밴드가 본체 높이에서 차지하는 비율. 셋을 더하면 1이다.
    ///
    /// 화면이 가장 크고(경첩 글자가 들어갈 자리), 간판이 그다음이다. 틈은 두 amber 면을
    /// 가르기만 하면 되므로 얇지만, 실측에서 0.03은 긁힌 자국으로 보여 0.05로 올렸다.
    public static func heightFraction(_ band: Band) -> Double {
        switch band {
        case .marquee: 0.24
        case .bezel:   0.05
        case .screen:  0.71
        }
    }

    /// 본체 위쪽 끝에서 이 밴드가 시작하는 지점(본체 높이 대비).
    public static func startFraction(_ band: Band) -> Double {
        var offset = 0.0
        for candidate in Band.allCases {
            if candidate == band { return offset }
            offset += heightFraction(candidate)
        }
        return offset
    }

    /// 화면이 본체 좌우에서 물러나는 정도(본체 폭 대비, 한쪽).
    ///
    /// 간판은 본체 폭을 꽉 채우고 화면은 물러난다. 둘 다 꽉 채우면 같은 amber 덩어리에
    /// 줄 하나 그은 것으로 보이는데(실측), 화면이 물러나면 어두운 테두리가 삼면을 감싸
    /// "캐비닛 얼굴에 박힌 디스플레이"로 읽힌다.
    public static let screenInsetRatio: Double = 0.08

    /// amber가 플레이트에서 **실제로** 덮는 넓이. 화면이 좌우로 물러난 만큼을 뺀 값이다.
    ///
    /// 어두운 배경화면 위에서 어두운 아이콘은 구멍처럼 보인다. 이 값이 Dock에서의
    /// 존재감을 정하므로 기하를 손볼 때마다 다시 확인해야 한다.
    public static var accentCoverage: Double {
        let lit = body.width * body.height
        let marquee = lit * heightFraction(.marquee)
        let screen = body.width * (1 - 2 * screenInsetRatio)
            * body.height * heightFraction(.screen)
        return marquee + screen
    }

    /// 경첩 글자의 대문자 높이 ÷ 화면 밴드 높이.
    ///
    /// 꽉 채우지 않는다 — 화면은 글자를 담는 상자가 아니라 화면이고, 여백이 있어야
    /// 글자가 표시된 것처럼 보인다.
    public static let hingeLetterHeightRatio: Double = 0.62

    /// 조작판 버튼의 중심 x(조작판 폭 대비)와 지름(조작판 폭 대비).
    public static let controlButtonCenterXs: [Double] = [0.36, 0.64]
    public static let controlButtonDiameterRatio: Double = 0.07

    // MARK: - 크기별 단순화

    /// 경첩 글자를 그리기 시작하는 픽셀 크기.
    ///
    /// 이보다 작으면 글자가 amber 면 안의 얼룩이 된다 — 정보를 더하는 게 아니라
    /// 실루엣을 흐린다. 한 장을 축소하지 않고 크기마다 다시 그리는 이유가 이것이다.
    public static let hingeLetterMinimumPixelSize = 64

    /// 조작판 버튼과 모서리 선을 그리기 시작하는 픽셀 크기.
    /// 경첩 글자보다 늦게 나타난다 — 덜 중요한 것이 먼저 사라져야 한다.
    public static let controlDetailMinimumPixelSize = 256

    public static func showsHingeLetter(atPixelSize size: Int) -> Bool {
        size >= hingeLetterMinimumPixelSize
    }

    /// 본체 얼굴을 간판·틈·화면으로 나눠 그릴지, 한 덩어리로 칠할지.
    ///
    /// 경첩 글자와 **같은 임계값을 일부러 공유한다.** 이보다 작으면 틈(본체 높이의 5%)이
    /// 1픽셀 아래로 내려가 amber 위에 흙탕물 같은 띠로 뭉개진다(실측) — 구조를 보여주는
    /// 게 아니라 실루엣을 더럽힌다. 글자가 사라지는 크기와 구조가 사라지는 크기가
    /// 같은 것은 우연이 아니다: 둘 다 "여기서부터는 덩어리만 남는다"는 같은 사실이다.
    public static func showsFaceBands(atPixelSize size: Int) -> Bool {
        showsHingeLetter(atPixelSize: size)
    }

    public static func showsControlDetails(atPixelSize size: Int) -> Bool {
        size >= controlDetailMinimumPixelSize
    }

    // MARK: - iconset 슬롯

    /// `.iconset` 안의 PNG 한 장.
    public struct Slot: Sendable, Equatable {
        /// 포인트 크기. 파일 이름에 들어가는 숫자다.
        public let baseSize: Int
        /// 배율. 1 또는 2.
        public let scale: Int

        public var pixelSize: Int { baseSize * scale }

        /// `iconutil`이 요구하는 이름. 틀리면 변환이 실패하거나 그 크기만 보간된다.
        public var fileName: String {
            let suffix = scale == 1 ? "" : "@\(scale)x"
            return "icon_\(baseSize)x\(baseSize)\(suffix).png"
        }
    }

    /// macOS가 요구하는 열 장. 실제로 그려야 하는 픽셀 크기는 일곱 가지다 —
    /// 32·128·256·512는 두 슬롯이 공유하므로 렌더러가 캐시할 수 있다.
    public static let slots: [Slot] = [16, 32, 128, 256, 512].flatMap { base in
        [Slot(baseSize: base, scale: 1), Slot(baseSize: base, scale: 2)]
    }
}
