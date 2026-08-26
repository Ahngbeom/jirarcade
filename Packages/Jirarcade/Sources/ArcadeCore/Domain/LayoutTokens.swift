import Foundation

/// 창 폭에 따라 달라지는 치수·타이포 스케일.
///
/// `PaletteTokens`와 같은 자리에 같은 이유로 있다: 판단은 여기서 끝내고 `ArcadeUI`는
/// `Font`·`CGFloat`로 옮기기만 한다. `ArcadeUI`에는 테스트 타깃이 없어서
/// (`ModuleBoundaryTests`가 뷰 배선을 소스 텍스트로 지키는 이유가 그것이다) 숫자를
/// 고르는 판단이 그쪽으로 넘어가면 검증할 방법이 사라진다.
///
/// 이 앱의 기본 창은 1920×1080 디스플레이를 기준으로 잡혀 있다(`defaultWindow`).
/// 그 폭에서 쓰이는 값이 `wide` 열이고, 나머지 두 열은 창을 줄였을 때의 대비다.
public enum LayoutTokens {
    /// 창 폭이 만드는 세 구간. `allCases`는 좁은 것부터 넓은 것 순이며, 이 순서에
    /// 밀도별 단조 증가 검사가 기대고 있다.
    public enum Density: Sendable, CaseIterable, Equatable {
        case compact, regular, wide
    }

    /// 활자의 세 역할. 아케이드 캐비닛이 실제로 쓰는 활자 체계를 그대로 옮긴 것이다.
    ///
    /// - `marquee`: 캐비닛 상단 간판. 화면 제목에만 쓴다.
    /// - `readout`: 스코어보드. 라벨·수치·눈금처럼 자릿수가 흔들리면 안 되는 것.
    /// - `prose`: 문장. 한글 안내문은 모노스페이스가 아니라 본문 서체로 읽힌다.
    public enum TypeRole: Sendable, CaseIterable, Equatable {
        case marquee, readout, prose
    }

    /// 역할 안의 크기 단계. 작은 것부터 큰 것 순이다.
    public enum TypeStep: Sendable, CaseIterable, Equatable {
        case xs, s, m, l, xl
    }

    /// 여백 토큰.
    public enum SpaceToken: Sendable, CaseIterable, Equatable {
        /// 화면 좌우 바깥 여백.
        case gutter
        /// 서로 다른 성격의 블록 사이.
        case sectionGap
        /// 같은 블록 안 줄 사이.
        case rowGap
        /// 한 줄 안에서 붙어 있는 요소 사이.
        case tightGap
    }

    /// 고정 치수 토큰.
    public enum SizeToken: Sendable, CaseIterable, Equatable {
        case cabinetWidth, cabinetHeight
        case ticketCardWidth, ticketCardHeight
        /// 축 위에서 카드 사이에 최소로 남길 가로 여백. `LanePacker`가 이보다 좁아지면
        /// 다음 줄로 내린다 — 세로 줄 간격(`rowGap`)과 역할이 달라 따로 둔다.
        case ticketCardGap
        /// 진행률 바처럼 늘어나면 곤란한 것의 폭.
        case progressBarWidth
        case sheetMinWidth, sheetMinHeight
        /// 로그인 폼처럼 한 열로 읽는 것의 최대 폭.
        case formMaxWidth
        /// 매핑 마법사처럼 라벨과 컨트롤이 좌우로 갈리는 것의 최대 폭.
        case wizardMaxWidth
        /// 본문에 그리는 표의 한 칸 최대 폭. 칸 하나에 긴 문장이 들어 있으면 격자가
        /// 화면 밖까지 늘어나므로 상한을 두고, 넘으면 그 칸 안에서 줄바꿈한다.
        case tableCellMaxWidth
    }

    public struct WindowSize: Sendable, Equatable {
        public let width: Double
        public let height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// 이보다 좁아지면 보드의 레인 넷과 축이 읽히지 않는다.
    public static let minimumWindow = WindowSize(width: 1120, height: 720)

    /// 1920×1080에서 메뉴 막대와 Dock을 빼고도 여유 있게 들어가는 크기.
    /// 사용자가 창을 조절하면 macOS가 그 크기를 기억하므로 이 값은 첫 실행에만 쓰인다.
    public static let defaultWindow = WindowSize(width: 1600, height: 960)

    /// 쓸 수 있는 영역 안에 들어가는 기본 창 크기.
    ///
    /// `defaultWindow`는 1920×1080을 기준으로 잡은 값이지만 이 앱은 그보다 좁은
    /// 내장 화면에서도 열린다. 클램프하지 않으면 창 아래쪽이 Dock 밑으로, 오른쪽이
    /// 화면 밖으로 나가 버튼에 닿을 수 없게 된다.
    public static func fittedWindow(within available: WindowSize) -> WindowSize {
        WindowSize(width: min(defaultWindow.width, available.width),
                   height: min(defaultWindow.height, available.height))
    }

    /// 창 폭이 어느 구간에 드는가.
    ///
    /// 0 이하는 `compact`로 본다 — `GeometryReader`가 레이아웃 첫 패스에서 0을 주는
    /// 순간이 있고, 그때 넓은 밀도의 큰 치수를 적용하면 첫 프레임이 잘린다.
    public static func density(forWidth width: Double) -> Density {
        switch width {
        case ..<1240: .compact
        case ..<1560: .regular
        default:      .wide
        }
    }

    public static func fontSize(_ role: TypeRole, _ step: TypeStep, in density: Density) -> Double {
        pick(fontScale(role, step), density)
    }

    /// 자간. marquee에만 붙인다 — 모노스페이스에 자간을 더하면 숫자 정렬이 흔들려
    /// 스코어보드로서의 성질을 잃고, 문장은 기본 자간이 이미 최적이다.
    public static func tracking(_ role: TypeRole, _ step: TypeStep, in density: Density) -> Double {
        guard role == .marquee else { return 0 }
        // 크기에 비례시킨다. 고정 pt로 두면 작은 제목에서는 글자가 흩어지고
        // 큰 제목에서는 자간이 티나지 않는다.
        return fontSize(role, step, in: density) * 0.04
    }

    public static func space(_ token: SpaceToken, in density: Density) -> Double {
        switch token {
        case .gutter:     pick((20, 28, 40), density)
        case .sectionGap: pick((16, 20, 28), density)
        case .rowGap:     pick(( 8, 10, 12), density)
        case .tightGap:   pick(( 4,  6,  8), density)
        }
    }

    public static func size(_ token: SizeToken, in density: Density) -> Double {
        switch token {
        // 세로형 업라이트 캐비닛. 어느 밀도에서도 세로가 가로보다 길어야 실제
        // 업라이트로 읽힌다 — 정사각에 가까우면 그냥 타일이다.
        case .cabinetWidth:     pick((220, 260, 300), density)
        case .cabinetHeight:    pick((280, 350, 420), density)
        // 카드가 커지면 `BoardMetrics.minimumSpacing`도 함께 커져 `LanePacker`가
        // 자연히 더 여유 있게 쌓는다 — 패킹 규칙은 건드리지 않는다.
        case .ticketCardWidth:  pick((132, 150, 172), density)
        // 카드 높이만 폭에 비례해 고르지 않는다. 카드 안에 들어갈 것이 정해져 있어
        // 필요한 높이가 계산되기 때문이다: 상하 패딩(2×rowGap) + 줄 간격(6×cardLineGap)
        // + 글자. compact에서 글자가 85pt이므로 16 + 18 + 85 = 119 → 120, 그 위 밀도는
        // 세 항이 모두 커진 값이다(20 + 27 + 94, 24 + 36 + 102). 근거가 되는 상태별
        // 실측은 `BoardMetrics.cardHeight`에 있다 — 이 값을 고칠 때는 거기부터 읽는다.
        case .ticketCardHeight: pick((120, 142, 162), density)
        case .ticketCardGap:    pick(( 10,  12,  14), density)
        case .progressBarWidth: pick((110, 130, 160), density)
        case .sheetMinWidth:    pick((420, 540, 640), density)
        case .sheetMinHeight:   pick((320, 400, 480), density)
        case .formMaxWidth:     pick((480, 560, 640), density)
        case .wizardMaxWidth:   pick((560, 660, 760), density)
        // 카드 폭(`ticketCardWidth` × 2.8)에 세 칸이 들어가는 값. 표는 대개 두세 칸이다.
        case .tableCellMaxWidth: pick((150, 170, 200), density)
        }
    }

    /// (compact, regular, wide) 세 열에서 하나를 고른다.
    private static func pick(_ values: (Double, Double, Double), _ density: Density) -> Double {
        switch density {
        case .compact: values.0
        case .regular: values.1
        case .wide:    values.2
        }
    }

    /// marquee의 `xs`·`s`는 `m`으로 접는다. 간판을 9pt로 쓰는 화면은 없고, 접지
    /// 않으면 호출부의 실수가 조용히 통과한다.
    private static func fontScale(_ role: TypeRole, _ step: TypeStep) -> (Double, Double, Double) {
        switch role {
        case .marquee:
            switch step {
            case .xs, .s, .m: (20, 22, 24)
            case .l:          (24, 28, 32)
            case .xl:         (34, 40, 46)
            }
        case .readout:
            switch step {
            case .xs: ( 9, 10, 11)
            case .s:  (10, 11, 12)
            case .m:  (11, 12, 13)
            case .l:  (13, 15, 16)
            case .xl: (15, 17, 19)
            }
        case .prose:
            switch step {
            case .xs: (10, 11, 12)
            case .s:  (11, 12, 13)
            case .m:  (13, 14, 15)
            case .l:  (15, 17, 18)
            case .xl: (17, 19, 21)
            }
        }
    }
}
