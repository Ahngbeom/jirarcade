import Testing
import Foundation
@testable import ArcadeCore
import JiraKit

private func doc(_ blocks: ADFNode...) -> ADFNode {
    ADFNode(type: "doc", content: blocks)
}
private func para(_ inlines: ADFNode...) -> ADFNode {
    ADFNode(type: "paragraph", content: inlines)
}
private func text(_ value: String) -> ADFNode {
    ADFNode(type: "text", text: value)
}

@Test func paragraphsAreSeparatedByABlankLine() {
    let rendered = ADFRenderer.plainText(from: doc(para(text("위")), para(text("아래"))))

    #expect(rendered == "위\n\n아래")
}

@Test func hardBreakIsASingleNewline() {
    let rendered = ADFRenderer.plainText(
        from: doc(para(text("한 줄"), ADFNode(type: "hardBreak"), text("다음 줄")))
    )

    #expect(rendered == "한 줄\n다음 줄")
}

@Test func mentionAndEmojiAndInlineCardBecomeReadableText() {
    let rendered = ADFRenderer.plainText(from: doc(para(
        ADFNode(type: "mention", attrs: ["text": "@이름"]),
        text(" "),
        ADFNode(type: "emoji", attrs: ["text": "👍", "shortName": ":+1:"]),
        text(" "),
        ADFNode(type: "inlineCard", attrs: ["url": "https://example.atlassian.net/browse/DEMO-1"])
    )))

    #expect(rendered == "@이름 👍 https://example.atlassian.net/browse/DEMO-1")
}

/// emoji에 text가 없으면 shortName으로 떨어진다. 아무것도 안 그리면 문장에
/// 구멍이 생긴다.
@Test func emojiFallsBackToShortName() {
    let rendered = ADFRenderer.plainText(
        from: doc(para(ADFNode(type: "emoji", attrs: ["shortName": ":tada:"])))
    )

    #expect(rendered == ":tada:")
}

@Test func listsGetTheirMarkers() {
    let item = { (value: String) in
        ADFNode(type: "listItem", content: [para(text(value))])
    }
    let bullet = ADFNode(type: "bulletList", content: [item("하나"), item("둘")])
    let ordered = ADFNode(type: "orderedList", content: [item("첫째"), item("둘째")])

    #expect(ADFRenderer.plainText(from: doc(bullet)) == "• 하나\n• 둘")
    #expect(ADFRenderer.plainText(from: doc(ordered)) == "1. 첫째\n2. 둘째")
}

@Test func codeBlockIsIndentedAndQuoteIsPrefixed() {
    let code = ADFNode(type: "codeBlock", content: [text("let x = 1")])
    let quote = ADFNode(type: "blockquote", content: [para(text("인용"))])

    #expect(ADFRenderer.plainText(from: doc(code)) == "    let x = 1")
    #expect(ADFRenderer.plainText(from: doc(quote)) == "> 인용")
}

@Test func attachmentsAndTablesBecomePlaceholders() {
    let media = ADFNode(type: "mediaSingle", content: [ADFNode(type: "media")])
    let table = ADFNode(type: "table", content: [])

    #expect(ADFRenderer.plainText(from: doc(media)) == ADFRenderer.attachmentPlaceholder)
    #expect(ADFRenderer.plainText(from: doc(table)) == ADFRenderer.tablePlaceholder)
}

/// 이 테스트가 이 파일에서 가장 중요하다. Atlassian은 노드 타입을 예고 없이
/// 추가하고, 모르는 것을 빠뜨리면 사용자는 본문이 짧아진 것을 알아내지 못한다.
@Test func anUnknownNodeLeavesAVisibleMark() {
    let rendered = ADFRenderer.plainText(
        from: doc(ADFNode(type: "someFutureNodeType", content: []))
    )

    #expect(rendered == ADFRenderer.unsupportedPlaceholder)
}

@Test func anUnknownInlineNodeAlsoLeavesAMark() {
    let rendered = ADFRenderer.plainText(
        from: doc(para(text("앞 "), ADFNode(type: "futureInline"), text(" 뒤")))
    )

    #expect(rendered == "앞 \(ADFRenderer.unsupportedPlaceholder) 뒤")
}

@Test func emptyBlocksDoNotLeaveStrayBlankLines() {
    let rendered = ADFRenderer.plainText(from: doc(para(text("하나")), para(), para(text("둘"))))

    #expect(rendered == "하나\n\n둘")
}
