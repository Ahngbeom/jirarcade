import Foundation
import JiraKit

/// ADF 트리를 화면에 그릴 `RichDocument`로 옮긴다.
///
/// 모르는 노드를 빠뜨리지 않는다. 빠뜨리면 본문 일부가 없는 채로 보이고 사용자는
/// 그게 전부인 줄 안다. 자리표시자가 있으면 "여기 뭔가 더 있다"가 보이고 Jira로 갈
/// 수 있다. Atlassian이 노드 타입을 예고 없이 추가하므로 이 성질이 필요하다.
///
/// **읽기 전용이다.** 여기서 만든 값은 Jira로 돌아가지 않는다 — 본문 편집은 아직 없고,
/// 열더라도 이 값이 아니라 원본 ADF에서 판정해야 한다(`ADFNode.hasMarks`).
public enum ADFRenderer {
    public static let attachmentPlaceholder = "[첨부]"
    public static let tablePlaceholder = "[표]"
    public static let unsupportedPlaceholder = "[지원하지 않는 서식]"

    public static func document(from doc: ADFNode) -> RichDocument {
        RichDocument(blocks: blocks(doc.content))
    }

    // MARK: - 블록

    private static func blocks(_ nodes: [ADFNode]) -> [RichBlock] {
        nodes.flatMap(blocks(of:))
    }

    /// 노드 하나가 블록 **여럿**을 낼 수 있다 — `mediaGroup` 하나에 첨부가 여럿 들어온다.
    ///
    /// 빈 배열을 돌려주는 경우는 **내용이 정말로 없을 때뿐이다.** 빈 문단이 자리를
    /// 차지하면 본문에 원인 없는 빈 줄이 생긴다. 모르는 노드는 빈 배열이 아니라
    /// 자리표시자다.
    private static func blocks(of node: ADFNode) -> [RichBlock] {
        switch node.type {
        case "paragraph":
            let runs = inline(node.content)
            return runs.isEmpty ? [] : [.paragraph(runs)]

        case "heading":
            let runs = inline(node.content)
            guard !runs.isEmpty else { return [] }
            // 단계를 모르면 1로 본다 — 제목인 것은 확실하고, 크기는 짐작이 필요하다.
            let level = min(max(Int(node.attrs["level"] ?? "") ?? 1, 1), 6)
            return [.heading(level: level, runs: runs)]

        case "codeBlock":
            // 코드 안에서는 서식을 무시하고 글자만 잇는다 — 코드에 굵게가 붙어 있어도
            // 그것을 그리는 순간 코드가 아니게 된다.
            let text = inline(node.content).map(\.text).joined()
            return text.isEmpty ? [] : [.code(language: node.attrs["language"], text: text)]

        case "blockquote":
            let inner = blocks(node.content)
            return inner.isEmpty ? [] : [.quote(inner)]

        case "bulletList":
            let items = listItems(node.content)
            return items.isEmpty ? [] : [.list(RichList(isOrdered: false, items: items))]

        case "orderedList":
            let items = listItems(node.content)
            guard !items.isEmpty else { return [] }
            return [.list(RichList(isOrdered: true,
                                   start: Int(node.attrs["order"] ?? "") ?? 1,
                                   items: items))]

        case "rule":
            return [.rule]

        case "panel":
            let inner = blocks(node.content)
            guard !inner.isEmpty else { return [] }
            // 모르는 종류는 중립인 note로 둔다. 색이 하나 어긋나는 것과 패널이 통째로
            // 자리표시자가 되는 것 중에서는 전자가 낫다 — 안의 글자는 그대로 읽힌다.
            let kind = RichPanelKind(rawValue: node.attrs["panelType"] ?? "") ?? .note
            return [.panel(kind: kind, blocks: inner)]

        case "expand", "nestedExpand":
            let inner = blocks(node.content)
            guard !inner.isEmpty else { return [] }
            let title = node.attrs["title"].map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return [.expand(title: title.isEmpty ? "펼치기" : title, blocks: inner)]

        case "mediaSingle", "mediaGroup":
            let children = node.content.flatMap(blocks(of:))
            // 껍데기만 오고 안이 비어 있어도 첨부가 있었다는 사실은 남긴다.
            return children.isEmpty ? [.attachment(label: attachmentPlaceholder)] : children

        case "media", "mediaInline":
            // 파일 이름은 `alt`에만 오고, 없는 경우가 흔하다.
            let alt = node.attrs["alt"]?.trimmingCharacters(in: .whitespaces) ?? ""
            return [.attachment(label: alt.isEmpty ? attachmentPlaceholder : alt)]

        case "table":
            let rows = node.content.compactMap(tableRow)
            // 행이 하나도 없으면 격자로 그릴 것이 없다. 자리표시자로 남겨 표가 있었다는
            // 사실이 사라지지 않게 한다.
            return [rows.isEmpty ? .unsupported(label: tablePlaceholder)
                                 : .table(RichTable(rows: rows))]

        default:
            return [.unsupported(label: unsupportedPlaceholder)]
        }
    }

    private static func listItems(_ nodes: [ADFNode]) -> [[RichBlock]] {
        nodes.compactMap { item in
            guard item.type == "listItem" else { return nil }
            let inner = blocks(item.content)
            return inner.isEmpty ? nil : inner
        }
    }

    private static func tableRow(_ node: ADFNode) -> RichTableRow? {
        guard node.type == "tableRow" else { return nil }
        let cells = node.content.compactMap(tableCell)
        return cells.isEmpty ? nil : RichTableRow(cells: cells)
    }

    private static func tableCell(_ node: ADFNode) -> RichTableCell? {
        guard node.type == "tableCell" || node.type == "tableHeader" else { return nil }
        // 빈 칸은 표의 모양을 이룬다 — 지우면 오른쪽 칸들이 한 칸씩 밀린다.
        return RichTableCell(
            isHeader: node.type == "tableHeader",
            columnSpan: Int(node.attrs["colspan"] ?? "") ?? 1,
            blocks: blocks(node.content)
        )
    }

    // MARK: - 인라인

    /// 인라인 노드들을 서식이 붙은 구간으로 옮긴다. 서식이 같은 이웃은 하나로 합친다 —
    /// 붙이지 않으면 Jira가 글자마다 쪼개 보낸 텍스트가 그만큼의 조각으로 남는다.
    private static func inline(_ nodes: [ADFNode]) -> [RichRun] {
        var runs: [RichRun] = []
        for node in nodes {
            guard let run = self.run(node) else { continue }
            if let last = runs.last, last.style == run.style, last.link == run.link {
                runs[runs.count - 1] = RichRun(text: last.text + run.text,
                                               style: last.style, link: last.link)
            } else {
                runs.append(run)
            }
        }
        // 통째로 공백뿐인 문단은 내용이 없는 것으로 본다.
        return runs.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ? runs : []
    }

    private static func run(_ node: ADFNode) -> RichRun? {
        let style = self.style(node.marks)
        let link = self.link(node.marks)

        switch node.type {
        case "text":
            guard let text = node.text, !text.isEmpty else { return nil }
            return RichRun(text: text, style: style, link: link)
        case "hardBreak":
            return RichRun(text: "\n")
        case "mention":
            return node.attrs["text"].map { RichRun(text: $0, style: style.union(.bold)) }
                ?? RichRun(text: unsupportedPlaceholder)
        case "emoji":
            let text = node.attrs["text"] ?? node.attrs["shortName"]
            return RichRun(text: text ?? unsupportedPlaceholder, style: style)
        case "status":
            // Jira의 색 알약. 색은 버리고 글자만 남기되, 문장 안에서 구분되게 감싼다.
            return node.attrs["text"].map { RichRun(text: "[\($0)]", style: style.union(.bold)) }
                ?? RichRun(text: unsupportedPlaceholder)
        case "inlineCard":
            guard let url = node.attrs["url"] else { return RichRun(text: unsupportedPlaceholder) }
            return RichRun(text: url, style: style, link: URL(string: url))
        default:
            return RichRun(text: unsupportedPlaceholder)
        }
    }

    private static func style(_ marks: [ADFMark]) -> RichStyle {
        var style: RichStyle = []
        for mark in marks {
            switch mark.type {
            case "strong":       style.insert(.bold)
            case "em":           style.insert(.italic)
            case "code":         style.insert(.code)
            case "strike":       style.insert(.strikethrough)
            case "underline":    style.insert(.underline)
            // 색·배경색은 일부러 버린다(`RichStyle` 참고). subsup·alignment는 그릴
            // 자리가 없다. 어느 쪽이든 글자는 남으므로 자리표시자를 넣지 않는다.
            default:             continue
            }
        }
        return style
    }

    private static func link(_ marks: [ADFMark]) -> URL? {
        marks.first { $0.type == "link" }
            .flatMap { $0.attrs["href"] }
            .flatMap(URL.init(string:))
    }
}
