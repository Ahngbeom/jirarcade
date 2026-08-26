import Foundation

/// 화면에 그릴 문서의 값 표현. ADF를 옮겨 담은 결과이고, SwiftUI를 모른다.
///
/// **왜 평문이 아니라 이 구조인가:** 예전에는 ADF를 문자열 하나로 눕혀 그렸다. 글자는
/// 남았지만 굵게·링크·표·코드블록이 사라져서, 남이 정성껏 쓴 본문이 이 앱에서만
/// 뭉개진 채로 보였다. 그렇다고 뷰가 ADF 트리를 직접 받으면 "무엇을 어떻게 그릴지"의
/// 판단이 `ArcadeUI`로 넘어가는데, 그 모듈에는 테스트 타깃이 없다.
///
/// 그래서 판단은 전부 여기서 끝낸다 — 목록의 중첩, 표의 행과 열, 모르는 노드의
/// 자리표시자까지. `ArcadeUI`는 이 값을 뷰로 옮기기만 한다.
public struct RichDocument: Sendable, Equatable {
    public let blocks: [RichBlock]

    public init(blocks: [RichBlock]) {
        self.blocks = blocks
    }

    public static let empty = RichDocument(blocks: [])

    public var isEmpty: Bool { blocks.isEmpty }
}

/// 한 줄 안에서 같은 서식이 이어지는 구간.
public struct RichRun: Sendable, Equatable {
    public let text: String
    public let style: RichStyle
    /// 링크가 붙어 있으면 그 주소. 파싱에 실패한 주소는 nil이고 글자만 남는다.
    public let link: URL?

    public init(text: String, style: RichStyle = [], link: URL? = nil) {
        self.text = text
        self.style = style
        self.link = link
    }
}

/// 글자에 붙는 서식.
///
/// 글자 **색**(`textColor`·`backgroundColor`)은 담지 않는다. 이 앱의 색은 팔레트에서만
/// 오고 대비가 테스트로 검증돼 있는데(`ContrastTests`), 남의 문서가 지정한 임의의 색을
/// 그대로 칠하면 다크 테마에서 읽을 수 없는 글자가 생긴다. 색을 잃어도 글자는 남는다.
public struct RichStyle: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = RichStyle(rawValue: 1 << 0)
    public static let italic = RichStyle(rawValue: 1 << 1)
    public static let code = RichStyle(rawValue: 1 << 2)
    public static let strikethrough = RichStyle(rawValue: 1 << 3)
    public static let underline = RichStyle(rawValue: 1 << 4)
}

/// 문서를 이루는 덩어리 하나.
///
/// `indirect`가 없어도 되는 이유: 재귀가 전부 배열을 거친다.
public enum RichBlock: Sendable, Equatable {
    case paragraph([RichRun])
    /// `level`은 1...6으로 조인다 — Jira가 그 밖의 값을 주더라도 화면의 활자 단계는 여섯뿐이다.
    case heading(level: Int, runs: [RichRun])
    case code(language: String?, text: String)
    case quote([RichBlock])
    case list(RichList)
    case rule
    case panel(kind: RichPanelKind, blocks: [RichBlock])
    /// Jira의 접이식 블록. 제목이 없으면 앱이 짓는다 — 접힌 것을 여는 손잡이에 이름이
    /// 없으면 안에 무엇이 있는지 짐작할 수도, 열 이유를 알 수도 없다.
    case expand(title: String, blocks: [RichBlock])
    case table(RichTable)
    /// 첨부·이미지. 앱이 파일을 받아오지는 않으므로 있다는 사실과 이름만 남긴다.
    case attachment(label: String)
    /// 그릴 줄 모르는 노드. **빠뜨리지 않는다** — 빠뜨리면 본문 일부가 없는 채로 보이고
    /// 사용자는 그게 전부인 줄 안다. 자리표시자가 있으면 Jira로 갈 이유가 보인다.
    case unsupported(label: String)
}

public struct RichList: Sendable, Equatable {
    public let isOrdered: Bool
    /// 번호 목록이 시작하는 수. Jira는 중간부터 시작하는 목록을 만들 수 있다.
    public let start: Int
    /// 항목 하나가 여러 문단이거나 안에 또 목록을 품을 수 있어 블록 배열이다.
    public let items: [[RichBlock]]

    public init(isOrdered: Bool, start: Int = 1, items: [[RichBlock]]) {
        self.isOrdered = isOrdered
        self.start = start
        self.items = items
    }
}

public struct RichTable: Sendable, Equatable {
    public let rows: [RichTableRow]

    public init(rows: [RichTableRow]) {
        self.rows = rows
    }

    /// 가장 넓은 행의 칸 수. 뷰가 격자를 짤 때 쓴다 — 행마다 칸 수가 다른 표가 실제로 온다.
    public var columnCount: Int {
        rows.map { row in row.cells.reduce(0) { $0 + $1.columnSpan } }.max() ?? 0
    }
}

public struct RichTableRow: Sendable, Equatable {
    public let cells: [RichTableCell]

    public init(cells: [RichTableCell]) {
        self.cells = cells
    }
}

public struct RichTableCell: Sendable, Equatable {
    public let isHeader: Bool
    /// 가로로 몇 칸을 차지하는가. 세로 병합(`rowspan`)은 담지 않는다 — 뷰가 쓰는
    /// SwiftUI `Grid`에 대응하는 손잡이가 없다. 그 표는 칸이 밀려 보인다.
    public let columnSpan: Int
    public let blocks: [RichBlock]

    public init(isHeader: Bool, columnSpan: Int = 1, blocks: [RichBlock]) {
        self.isHeader = isHeader
        self.columnSpan = max(columnSpan, 1)
        self.blocks = blocks
    }
}

/// 패널의 성격. 색은 뷰가 팔레트에서 고른다 — 여기서는 무엇인지만 말한다.
public enum RichPanelKind: String, Sendable, Equatable, CaseIterable {
    case info, note, success, warning, error
}
