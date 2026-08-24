import Foundation
import JiraKit

/// ADF 트리를 화면에 그릴 평문으로 옮긴다.
///
/// 모르는 노드를 빠뜨리지 않는다. 빠뜨리면 본문 일부가 없는 채로 보이고 사용자는
/// 그게 전부인 줄 안다. 자리표시자가 있으면 "여기 뭔가 더 있다"가 보이고 Jira로 갈
/// 수 있다. Atlassian이 노드 타입을 예고 없이 추가하므로 이 성질이 필요하다.
///
/// `marks`(굵게·기울임·링크)는 무시한다 — 평문으로 그리므로 서식은 사라지지만
/// 글자는 남는다.
public enum ADFRenderer {
    public static let attachmentPlaceholder = "[첨부]"
    public static let tablePlaceholder = "[표]"
    public static let unsupportedPlaceholder = "[지원하지 않는 서식]"

    public static func plainText(from doc: ADFNode) -> String {
        doc.content
            .map(block)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func block(_ node: ADFNode) -> String {
        switch node.type {
        case "paragraph", "heading":
            return inline(node.content)
        case "codeBlock":
            return prefixing(inline(node.content), with: "    ")
        case "blockquote":
            let inner = node.content.map(block).filter { !$0.isEmpty }.joined(separator: "\n")
            return prefixing(inner, with: "> ")
        case "bulletList":
            return node.content.map { "• " + inline(listItemInlines($0)) }.joined(separator: "\n")
        case "orderedList":
            return node.content.enumerated()
                .map { "\($0.offset + 1). " + inline(listItemInlines($0.element)) }
                .joined(separator: "\n")
        case "rule":
            return "———"
        case "mediaSingle", "mediaGroup", "media":
            return attachmentPlaceholder
        case "table", "tableRow", "tableCell", "tableHeader":
            return tablePlaceholder
        default:
            return unsupportedPlaceholder
        }
    }

    /// `listItem`은 문단을 품는다. 항목 하나를 한 줄로 만들기 위해 안쪽 인라인만 모은다.
    private static func listItemInlines(_ item: ADFNode) -> [ADFNode] {
        item.content.flatMap { $0.type == "paragraph" ? $0.content : [$0] }
    }

    private static func inline(_ nodes: [ADFNode]) -> String {
        nodes.map { node in
            switch node.type {
            case "text":
                return node.text ?? ""
            case "hardBreak":
                return "\n"
            case "mention":
                return node.attrs["text"] ?? unsupportedPlaceholder
            case "emoji":
                return node.attrs["text"] ?? node.attrs["shortName"] ?? unsupportedPlaceholder
            case "inlineCard":
                return node.attrs["url"] ?? unsupportedPlaceholder
            default:
                return unsupportedPlaceholder
            }
        }.joined()
    }

    private static func prefixing(_ text: String, with marker: String) -> String {
        text.components(separatedBy: "\n").map { marker + $0 }.joined(separator: "\n")
    }
}
