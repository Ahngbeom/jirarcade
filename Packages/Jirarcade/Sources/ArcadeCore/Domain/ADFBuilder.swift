import Foundation
import JiraKit

/// 사용자가 입력한 평문을 Jira가 받는 ADF 문서로 옮긴다.
///
/// 규칙을 못박아 두는 이유: 애매하면 같은 입력이 두 가지 문서가 되고, 사용자는
/// 자기가 친 것과 다른 모양이 올라간 것을 나중에 발견한다.
public enum ADFBuilder {
    /// - 빈 줄(공백만 있는 줄 포함)이 문단 경계다. 몇 줄이 이어지든 경계 하나로 본다.
    /// - 문단 안의 줄바꿈 하나는 `hardBreak`다.
    /// - 앞뒤 공백은 잘라내고, 남는 것이 없으면 `nil`이다 — 빈 댓글은 보내지 않는다.
    public static func paragraphs(from text: String) -> ADFDocument? {
        // Normalize line endings first: CRLF and CR → LF only.
        // This prevents stray \r from reaching text nodes and breaking paragraph detection.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var paragraphs: [[String]] = []
        var current: [String] = []
        for line in trimmed.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        guard !paragraphs.isEmpty else { return nil }

        let blocks = paragraphs.map { lines -> ADFDocument.Block in
            var inlines: [ADFDocument.Inline] = []
            for (index, line) in lines.enumerated() {
                if index > 0 { inlines.append(.init(type: "hardBreak", text: nil)) }
                inlines.append(.init(type: "text", text: line))
            }
            return ADFDocument.Block(content: inlines)
        }
        return ADFDocument(content: blocks)
    }
}
