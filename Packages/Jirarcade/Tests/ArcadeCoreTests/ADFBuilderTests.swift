import Testing
import Foundation
@testable import ArcadeCore
import JiraKit

@Test func blankLineStartsANewParagraph() throws {
    let doc = try #require(ADFBuilder.paragraphs(from: "첫 문단\n\n둘째 문단"))

    #expect(doc.content.count == 2)
    #expect(doc.content[0].content == [.init(type: "text", text: "첫 문단")])
    #expect(doc.content[1].content == [.init(type: "text", text: "둘째 문단")])
}

/// 빈 줄이 몇 개든 경계 하나다. 세 번 엔터를 친 것과 두 번 친 것이 다른 결과를
/// 내면 같은 입력이 두 가지 문서가 된다.
@Test func manyBlankLinesAreStillOneBoundary() throws {
    let doc = try #require(ADFBuilder.paragraphs(from: "위\n\n\n\n아래"))

    #expect(doc.content.count == 2)
}

/// 문단 안의 줄바꿈 하나는 hardBreak다. 문단을 가르지 않는다.
@Test func singleNewlineBecomesHardBreak() throws {
    let doc = try #require(ADFBuilder.paragraphs(from: "한 줄\n다음 줄"))

    #expect(doc.content.count == 1)
    #expect(doc.content[0].content == [
        .init(type: "text", text: "한 줄"),
        .init(type: "hardBreak", text: nil),
        .init(type: "text", text: "다음 줄"),
    ])
}

@Test func whitespaceOnlyInputProducesNothing() {
    #expect(ADFBuilder.paragraphs(from: "   \n\n  ") == nil)
    #expect(ADFBuilder.paragraphs(from: "") == nil)
}

@Test func encodesToTheShapeJiraExpects() throws {
    let doc = try #require(ADFBuilder.paragraphs(from: "본문"))
    let data = try JSONEncoder().encode(doc)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(json["type"] as? String == "doc")
    #expect(json["version"] as? Int == 1)
}

/// CRLF line endings from Windows or web editors must not corrupt text.
/// Paragraph boundaries with CRLF must still split correctly, and no CR should appear in text nodes.
@Test func crlfAtParagraphBoundaryPreservesContentAndBoundary() throws {
    let doc = try #require(ADFBuilder.paragraphs(from: "첫 문단\r\n\r\n둘째 문단"))

    #expect(doc.content.count == 2)
    #expect(doc.content[0].content == [.init(type: "text", text: "첫 문단")])
    #expect(doc.content[1].content == [.init(type: "text", text: "둘째 문단")])
}

/// Mid-paragraph CRLF must become hardBreak with clean text nodes, no CR characters embedded.
@Test func crlfWithinParagraphBecomesCleanHardBreak() throws {
    let doc = try #require(ADFBuilder.paragraphs(from: "한 줄\r\n다음 줄"))

    #expect(doc.content.count == 1)
    #expect(doc.content[0].content == [
        .init(type: "text", text: "한 줄"),
        .init(type: "hardBreak", text: nil),
        .init(type: "text", text: "다음 줄"),
    ])
}
