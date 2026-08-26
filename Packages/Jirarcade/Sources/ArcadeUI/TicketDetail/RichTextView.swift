import SwiftUI
import ArcadeCore

/// `RichDocument`를 그린다. 본문과 댓글이 같은 뷰를 쓴다.
///
/// **판단이 없다.** 목록의 중첩, 표의 행과 열, 모르는 노드의 자리표시자는 전부
/// `ADFRenderer`가 이미 정했다(`RichText.swift` 참고). `ArcadeUI`에는 테스트 타깃이
/// 없으므로, 이 파일에 판단이 들어오는 순간 그것을 검증할 방법이 사라진다.
struct RichTextView: View {
    let document: RichDocument

    var body: some View {
        RichBlocksView(blocks: document.blocks)
    }
}

/// 블록 여럿을 세로로 쌓는다. 인용·패널·표의 칸이 다시 이 뷰를 쓰므로 재귀한다.
///
/// `ForEach`의 id를 위치로 삼는다 — 문서는 한 번에 통째로 다시 그려지는 정적인
/// 값이라 원소가 개별로 움직이지 않고, 그래서 모델에 식별자를 심을 이유가 없다.
private struct RichBlocksView: View {
    @Environment(\.arcadeMetrics) private var metrics
    let blocks: [RichBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowGap) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                RichBlockView(block: block)
            }
        }
    }
}

private struct RichBlockView: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
    let block: RichBlock

    var body: some View {
        switch block {
        case .paragraph(let runs):
            paragraph(runs)
                .arcadeType(.prose, .xs)
                .foregroundStyle(theme.inkPrimary)

        case .heading(let level, let runs):
            paragraph(runs)
                .arcadeType(.prose, headingStep(level), weight: .bold)
                .foregroundStyle(theme.inkPrimary)
                // 제목은 앞 블록과 더 떨어져야 다음 절이 시작한다는 것이 읽힌다.
                .padding(.top, metrics.tightGap)

        case .code(let language, let text):
            codeBlock(language: language, text: text)

        case .quote(let inner):
            HStack(alignment: .top, spacing: metrics.rowGap) {
                // 인용을 색이 아니라 세로 획으로 표시한다 — 팔레트에 인용 전용 색이 없고,
                // 있어야 할 이유도 없다(`TicketCardView`가 raid를 채움으로 가른 것과 같다).
                Rectangle()
                    .fill(theme.line)
                    .frame(width: 2)
                RichBlocksView(blocks: inner)
                    .foregroundStyle(theme.inkSecondary)
            }

        case .list(let list):
            listView(list)

        case .rule:
            Rectangle()
                .fill(theme.line)
                .frame(height: 1)
                .padding(.vertical, metrics.tightGap)

        case .panel(let kind, let inner):
            panel(kind: kind, blocks: inner)

        case .expand(let title, let inner):
            // Jira에서 접혀 있던 것은 여기서도 접힌 채 연다. 제목이 보이므로 내용이
            // 조용히 사라지는 것과 다르다 — 무엇이 들어 있는지 알고 열 수 있다.
            DisclosureGroup {
                RichBlocksView(blocks: inner)
                    .padding(.top, metrics.tightGap)
            } label: {
                Text(title)
                    .arcadeType(.readout, .xs, weight: .bold)
                    .foregroundStyle(theme.inkSecondary)
            }

        case .table(let table):
            RichTableView(table: table)

        case .attachment(let label):
            chip(label)

        case .unsupported(let label):
            // 자리표시자는 본문 글자와 같은 무게로 읽히면 안 된다 — 이것은 Jira에 있는
            // 내용이 아니라 "여기 우리가 못 그리는 것이 있다"는 앱의 말이다.
            Text(label)
                .arcadeType(.readout, .xs)
                .foregroundStyle(theme.inkTertiary)
        }
    }

    // MARK: - 문단

    /// 서식이 붙은 구간들을 하나의 `Text`로 만든다.
    ///
    /// `AttributedString`을 거치는 이유는 링크다. `Text`를 이어 붙이는 방식으로는 구간
    /// 하나만 누를 수 있게 만들 수 없고, 링크가 눌리지 않으면 티켓 본문에서 가장 자주
    /// 쓰이는 서식이 죽는다. 굵게·기울임은 `inlinePresentationIntent`로 얹으므로
    /// 글자 크기는 바깥의 `arcadeType`이 그대로 정한다 — 여기서 폰트를 짓지 않는다.
    private func paragraph(_ runs: [RichRun]) -> Text {
        var attributed = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            var intents: InlinePresentationIntent = []
            if run.style.contains(.bold) { intents.insert(.stronglyEmphasized) }
            if run.style.contains(.italic) { intents.insert(.emphasized) }
            if run.style.contains(.code) { intents.insert(.code) }
            if run.style.contains(.strikethrough) { intents.insert(.strikethrough) }
            if !intents.isEmpty { piece.inlinePresentationIntent = intents }
            if run.style.contains(.underline) { piece.underlineStyle = .single }
            if let link = run.link { piece.link = link }
            attributed.append(piece)
        }
        return Text(attributed)
    }

    /// 본문 글자(`.xs`)를 기준으로 여섯 단계를 세 크기에 접는다. 활자 스케일에 여섯
    /// 단계가 없고, 카드 안에서 h4와 h5를 구분해 봐야 읽는 사람에게 뜻이 없다.
    private func headingStep(_ level: Int) -> LayoutTokens.TypeStep {
        switch level {
        case 1:  .m
        case 2:  .s
        default: .xs
        }
    }

    // MARK: - 코드

    private func codeBlock(language: String?, text: String) -> some View {
        VStack(alignment: .leading, spacing: metrics.tightGap) {
            if let language, !language.isEmpty {
                Text(language)
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.inkTertiary)
            }
            // 코드는 줄바꿈하지 않고 가로로 민다. 접으면 들여쓰기가 뭉개져 코드가
            // 아니게 된다 — 표(`RichTableView`)와 같은 판단이다.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.inkPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(metrics.rowGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceBase)
        .overlay(Rectangle().strokeBorder(theme.line, lineWidth: 1))
    }

    // MARK: - 목록

    private func listView(_ list: RichList) -> some View {
        VStack(alignment: .leading, spacing: metrics.tightGap) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: metrics.tightGap) {
                    Text(marker(list, index: index))
                        .arcadeType(.readout, .xs)
                        .foregroundStyle(theme.inkTertiary)
                        .monospacedDigit()
                    RichBlocksView(blocks: item)
                }
            }
        }
    }

    /// 중첩 깊이에 따라 글머리 모양을 바꾸지 않는다. 들여쓰기가 이미 깊이를 말하고,
    /// 모양을 늘리면 그만큼 규칙이 늘어난다.
    private func marker(_ list: RichList, index: Int) -> String {
        list.isOrdered ? "\(list.start + index)." : "•"
    }

    // MARK: - 패널

    private func panel(kind: RichPanelKind, blocks: [RichBlock]) -> some View {
        HStack(alignment: .top, spacing: metrics.rowGap) {
            Rectangle()
                .fill(tint(kind))
                .frame(width: 3)
            RichBlocksView(blocks: blocks)
                .padding(.vertical, metrics.tightGap)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint(kind).opacity(0.10))
    }

    /// 패널의 성격을 팔레트의 색으로 옮긴다. 새 색을 만들지 않는다 — 팔레트는 대비가
    /// 검증된 열 개뿐이고(`ContrastTests`), 여기에 한 색을 더하면 그 검증부터 늘어난다.
    private func tint(_ kind: RichPanelKind) -> Color {
        switch kind {
        case .info:    theme.accent
        case .note:    theme.inkTertiary
        case .success: theme.good
        case .warning: theme.boss
        case .error:   theme.danger
        }
    }

    private func chip(_ label: String) -> some View {
        HStack(spacing: metrics.tightGap) {
            Text("◫")
                .arcadeType(.readout, .xs)
                .foregroundStyle(theme.inkTertiary)
            Text(label)
                .arcadeType(.readout, .xs)
                .foregroundStyle(theme.inkSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, metrics.rowGap)
        .padding(.vertical, metrics.tightGap)
        .overlay(Rectangle().strokeBorder(theme.line, lineWidth: 1))
    }
}

/// 표. 칸이 넓으면 가로로 민다 — 줄바꿈으로 접으면 열 정렬이 무너져 표가 아니게 된다.
private struct RichTableView: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
    let table: RichTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                            cellView(cell)
                                // 가로 병합은 `Grid`에 대응하는 손잡이가 있어 그대로 옮긴다.
                                // 세로 병합은 없어서 그 표는 칸이 밀려 보인다.
                                .gridCellColumns(cell.columnSpan)
                        }
                    }
                }
            }
            .overlay(Rectangle().strokeBorder(theme.line, lineWidth: 1))
        }
    }

    private func cellView(_ cell: RichTableCell) -> some View {
        RichBlocksView(blocks: cell.blocks)
            .frame(maxWidth: metrics.size(.tableCellMaxWidth), alignment: .topLeading)
            .padding(metrics.rowGap)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .fontWeight(cell.isHeader ? .bold : nil)
            .background(cell.isHeader ? theme.surfaceBase : Color.clear)
            .overlay(Rectangle().strokeBorder(theme.line, lineWidth: 0.5))
    }
}
