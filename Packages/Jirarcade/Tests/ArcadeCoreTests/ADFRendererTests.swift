import Testing
import Foundation
@testable import ArcadeCore
import JiraKit

// ADF 트리를 화면 구조(`RichDocument`)로 옮기는 경로.
//
// 이 판정이 `ArcadeCore`에 있는 이유: `ArcadeUI`에는 테스트 타깃이 없다. 목록의 중첩,
// 표의 행과 열, 모르는 노드의 자리표시자가 뷰로 넘어가면 아래 어느 것도 확인할 수 없다.

private func doc(_ blocks: ADFNode...) -> ADFNode {
    ADFNode(type: "doc", content: blocks)
}
private func para(_ inlines: ADFNode...) -> ADFNode {
    ADFNode(type: "paragraph", content: inlines)
}
private func text(_ value: String, marks: [ADFMark] = []) -> ADFNode {
    ADFNode(type: "text", text: value, marks: marks)
}
private func item(_ value: String) -> ADFNode {
    ADFNode(type: "listItem", content: [para(text(value))])
}

private func blocks(_ node: ADFNode) -> [RichBlock] {
    ADFRenderer.document(from: node).blocks
}

/// 블록 하나가 담은 글자. 서식이 아니라 **내용이 사라지지 않았는지**를 볼 때 쓴다.
private func plain(_ block: RichBlock) -> String {
    switch block {
    case .paragraph(let runs), .heading(_, let runs):
        return runs.map(\.text).joined()
    case .code(_, let text):
        return text
    case .quote(let inner), .panel(_, let inner), .expand(_, let inner):
        return inner.map(plain).joined(separator: "\n")
    case .list(let list):
        return list.items.map { $0.map(plain).joined(separator: "\n") }.joined(separator: "\n")
    case .table(let table):
        return table.rows
            .map { $0.cells.map { $0.blocks.map(plain).joined() }.joined(separator: "\t") }
            .joined(separator: "\n")
    case .rule:
        return "———"
    case .attachment(let label), .unsupported(let label):
        return label
    }
}

private func plain(_ blocks: [RichBlock]) -> String {
    blocks.map(plain).joined(separator: "\n\n")
}

private func runs(_ block: RichBlock?) -> [RichRun] {
    guard case .paragraph(let runs) = block else { return [] }
    return runs
}

// MARK: - 블록

@Test func eachParagraphBecomesItsOwnBlock() {
    let rendered = blocks(doc(para(text("위")), para(text("아래"))))

    #expect(rendered.count == 2)
    #expect(plain(rendered) == "위\n\n아래")
}

/// hardBreak는 문단을 가르지 않는다 — 같은 문단 안의 줄바꿈이다.
@Test func hardBreakStaysInsideTheParagraph() {
    let rendered = blocks(doc(para(text("한 줄"), ADFNode(type: "hardBreak"), text("다음 줄"))))

    #expect(rendered.count == 1)
    #expect(plain(rendered) == "한 줄\n다음 줄")
}

@Test func headingsCarryTheirLevel() {
    let h2 = ADFNode(type: "heading", attrs: ["level": "2"], content: [text("절")])

    guard case .heading(let level, let runs) = blocks(doc(h2)).first else {
        Issue.record("heading이 아니다: \(blocks(doc(h2)))")
        return
    }
    #expect(level == 2)
    #expect(runs.map(\.text) == ["절"])
}

/// 단계를 모르거나 범위를 벗어나도 제목이라는 사실은 남는다. 문단으로 떨어뜨리면
/// 문서의 뼈대가 사라진다.
@Test func aHeadingWithoutAUsableLevelIsStillAHeading() {
    let noLevel = ADFNode(type: "heading", content: [text("제목")])
    let absurd = ADFNode(type: "heading", attrs: ["level": "99"], content: [text("제목")])

    guard case .heading(let a, _) = blocks(doc(noLevel)).first,
          case .heading(let b, _) = blocks(doc(absurd)).first else {
        Issue.record("heading이 아니다")
        return
    }
    #expect(a == 1)
    #expect(b == 6)
}

@Test func listsKeepTheirKindAndItems() {
    let bullet = ADFNode(type: "bulletList", content: [item("하나"), item("둘")])
    let ordered = ADFNode(type: "orderedList", attrs: ["order": "3"],
                          content: [item("셋째"), item("넷째")])

    guard case .list(let unordered) = blocks(doc(bullet)).first,
          case .list(let numbered) = blocks(doc(ordered)).first else {
        Issue.record("list가 아니다")
        return
    }
    #expect(!unordered.isOrdered)
    #expect(unordered.items.count == 2)
    #expect(numbered.isOrdered)
    // Jira는 중간부터 시작하는 번호 목록을 만들 수 있다. 1부터 다시 세면 본문이 거짓말을 한다.
    #expect(numbered.start == 3)
}

/// 항목 안의 목록은 항목의 블록으로 남는다 — 평평하게 펴면 어느 항목에 딸린
/// 하위 항목인지가 사라진다.
@Test func aNestedListStaysInsideItsItem() {
    let nested = ADFNode(type: "bulletList", content: [item("안쪽 첫째"), item("안쪽 둘째")])
    let outer = ADFNode(type: "listItem", content: [para(text("바깥")), nested])

    guard case .list(let list) = blocks(doc(ADFNode(type: "bulletList", content: [outer]))).first,
          list.items.count == 1 else {
        Issue.record("list가 아니다")
        return
    }
    #expect(list.items[0].count == 2)
    guard case .list(let inner) = list.items[0][1] else {
        Issue.record("중첩 목록이 항목 안에 없다: \(list.items[0])")
        return
    }
    #expect(inner.items.count == 2)
}

@Test func codeBlockKeepsItsLanguageAndDropsFormatting() {
    let code = ADFNode(type: "codeBlock", attrs: ["language": "swift"],
                       content: [text("let x = 1", marks: [ADFMark(type: "strong")])])

    guard case .code(let language, let body) = blocks(doc(code)).first else {
        Issue.record("code가 아니다")
        return
    }
    #expect(language == "swift")
    // 코드에 굵게가 붙어 있어도 그리지 않는다 — 그리는 순간 코드가 아니게 된다.
    #expect(body == "let x = 1")
}

@Test func panelKeepsItsKindAndUnknownKindsStayNeutral() {
    let warning = ADFNode(type: "panel", attrs: ["panelType": "warning"],
                          content: [para(text("조심"))])
    let future = ADFNode(type: "panel", attrs: ["panelType": "somethingNew"],
                         content: [para(text("내용"))])

    guard case .panel(let kind, _) = blocks(doc(warning)).first,
          case .panel(let fallback, let inner) = blocks(doc(future)).first else {
        Issue.record("panel이 아니다")
        return
    }
    #expect(kind == .warning)
    // 모르는 종류는 중립으로 둔다. 색 하나가 어긋나도 안의 글자는 그대로 읽힌다.
    #expect(fallback == .note)
    #expect(plain(inner) == "내용")
}

@Test func expandKeepsItsTitleAndNamesTheUnnamed() {
    let titled = ADFNode(type: "expand", attrs: ["title": "자세히"], content: [para(text("속"))])
    let bare = ADFNode(type: "nestedExpand", content: [para(text("속"))])

    guard case .expand(let title, _) = blocks(doc(titled)).first,
          case .expand(let fallback, _) = blocks(doc(bare)).first else {
        Issue.record("expand가 아니다")
        return
    }
    #expect(title == "자세히")
    // 접힌 것을 여는 손잡이에 이름이 없으면 열 이유를 알 수 없다.
    #expect(fallback == "펼치기")
}

@Test func aTableBecomesAGridWithHeaderCells() {
    let header = ADFNode(type: "tableRow", content: [
        ADFNode(type: "tableHeader", content: [para(text("이름"))]),
        ADFNode(type: "tableHeader", content: [para(text("값"))]),
    ])
    let row = ADFNode(type: "tableRow", content: [
        ADFNode(type: "tableCell", content: [para(text("정체일"))]),
        ADFNode(type: "tableCell", content: [para(text("18"))]),
    ])

    guard case .table(let table) = blocks(doc(ADFNode(type: "table", content: [header, row]))).first
    else {
        Issue.record("table이 아니다")
        return
    }
    #expect(table.rows.count == 2)
    #expect(table.rows[0].cells.filter(\.isHeader).count == 2)
    #expect(table.rows[1].cells.filter(\.isHeader).isEmpty)
    #expect(plain(.table(table)) == "이름\t값\n정체일\t18")
}

/// 빈 칸은 표의 모양을 이룬다. 지우면 오른쪽 칸들이 한 칸씩 밀려 값이 다른 열에 붙는다.
@Test func anEmptyCellKeepsItsPlaceInTheRow() {
    let row = ADFNode(type: "tableRow", content: [
        ADFNode(type: "tableCell", content: []),
        ADFNode(type: "tableCell", content: [para(text("값"))]),
    ])

    guard case .table(let table) = blocks(doc(ADFNode(type: "table", content: [row]))).first else {
        Issue.record("table이 아니다")
        return
    }
    #expect(table.rows[0].cells.count == 2)
    #expect(table.rows[0].cells[0].blocks.isEmpty)
}

@Test func colspanIsCountedInTheColumnTotal() {
    let row = ADFNode(type: "tableRow", content: [
        ADFNode(type: "tableCell", attrs: ["colspan": "2"], content: [para(text("넓은 칸"))]),
        ADFNode(type: "tableCell", content: [para(text("좁은 칸"))]),
    ])

    guard case .table(let table) = blocks(doc(ADFNode(type: "table", content: [row]))).first else {
        Issue.record("table이 아니다")
        return
    }
    #expect(table.columnCount == 3)
}

/// 행이 없는 표는 격자로 그릴 것이 없다. 사라지게 두지 않고 자리표시자로 남긴다.
@Test func aTableWithNoRowsFallsBackToAPlaceholder() {
    let rendered = blocks(doc(ADFNode(type: "table", content: [])))

    #expect(rendered == [.unsupported(label: ADFRenderer.tablePlaceholder)])
}

@Test func mediaBecomesAnAttachmentPerFile() {
    let group = ADFNode(type: "mediaGroup", content: [
        ADFNode(type: "media", attrs: ["alt": "화면.png"]),
        ADFNode(type: "media"),
    ])

    #expect(blocks(doc(group)) == [
        .attachment(label: "화면.png"),
        .attachment(label: ADFRenderer.attachmentPlaceholder),
    ])
}

/// 껍데기만 오고 안이 비어 있어도 첨부가 있었다는 사실은 남는다.
@Test func anEmptyMediaWrapperStillLeavesAnAttachment() {
    #expect(blocks(doc(ADFNode(type: "mediaSingle", content: [])))
            == [.attachment(label: ADFRenderer.attachmentPlaceholder)])
}

@Test func aRuleSurvivesAsItsOwnBlock() {
    #expect(blocks(doc(ADFNode(type: "rule"))) == [.rule])
}

// MARK: - 사라지지 않는다

/// 이 테스트가 이 파일에서 가장 중요하다. Atlassian은 노드 타입을 예고 없이
/// 추가하고, 모르는 것을 빠뜨리면 사용자는 본문이 짧아진 것을 알아내지 못한다.
@Test func anUnknownBlockLeavesAVisibleMark() {
    #expect(blocks(doc(ADFNode(type: "someFutureNodeType", content: [])))
            == [.unsupported(label: ADFRenderer.unsupportedPlaceholder)])
}

/// 모르는 노드의 **자식**을 대신 그리지 않는다. 그 노드가 자식을 어떻게 배치하는지
/// 모르는 채로 펴면, 표를 문단으로 쏟는 것 같은 거짓말을 하게 된다.
@Test func anUnknownBlockDoesNotLeakItsChildren() {
    let unknown = ADFNode(type: "completelyUnknownType", content: [para(text("안쪽"))])

    #expect(blocks(doc(unknown)) == [.unsupported(label: ADFRenderer.unsupportedPlaceholder)])
}

@Test func anUnknownInlineNodeAlsoLeavesAMark() {
    let rendered = blocks(doc(para(text("앞 "), ADFNode(type: "futureInline"), text(" 뒤"))))

    #expect(plain(rendered) == "앞 \(ADFRenderer.unsupportedPlaceholder) 뒤")
}

@Test func emptyBlocksDoNotLeaveStrayGaps() {
    let rendered = blocks(doc(para(text("하나")), para(), para(text("   ")), para(text("둘"))))

    #expect(rendered.count == 2)
    #expect(plain(rendered) == "하나\n\n둘")
}

// MARK: - 인라인 서식

@Test func marksBecomeStyles() {
    let styled = para(
        text("굵게", marks: [ADFMark(type: "strong")]),
        text("기울임", marks: [ADFMark(type: "em")]),
        text("코드", marks: [ADFMark(type: "code")]),
        text("취소", marks: [ADFMark(type: "strike")]),
        text("밑줄", marks: [ADFMark(type: "underline")])
    )

    let styles = runs(blocks(doc(styled)).first).map(\.style)
    #expect(styles == [.bold, .italic, .code, .strikethrough, .underline])
}

@Test func aLinkKeepsItsDestination() {
    let linked = para(text("문서", marks: [
        ADFMark(type: "link", attrs: ["href": "https://example.atlassian.net/browse/DEMO-1"]),
    ]))

    let run = runs(blocks(doc(linked)).first).first
    #expect(run?.text == "문서")
    #expect(run?.link?.absoluteString == "https://example.atlassian.net/browse/DEMO-1")
}

/// 주소를 읽지 못해도 글자는 남는다. 링크 하나 때문에 문장에 구멍이 생기면 안 된다.
@Test func anUnusableLinkStillLeavesItsText() {
    let broken = para(text("깨진 링크", marks: [ADFMark(type: "link", attrs: [:])]))

    let run = runs(blocks(doc(broken)).first).first
    #expect(run?.text == "깨진 링크")
    #expect(run?.link == nil)
}

/// 글자 색은 일부러 버린다. 팔레트 밖의 색을 그대로 칠하면 반대 테마에서 읽을 수 없다.
@Test func textColorIsDroppedButTheTextIsNot() {
    let colored = para(text("빨간 글씨", marks: [
        ADFMark(type: "textColor", attrs: ["color": "#ff0000"]),
        ADFMark(type: "strong"),
    ]))

    let run = runs(blocks(doc(colored)).first).first
    #expect(run?.text == "빨간 글씨")
    #expect(run?.style == .bold)
}

/// 서식이 같은 이웃은 하나로 합친다. Jira는 같은 문장을 여러 조각으로 쪼개 보낸다.
@Test func adjacentRunsWithTheSameStyleAreMerged() {
    let split = para(text("한 "), text("문장"), text("굵게", marks: [ADFMark(type: "strong")]))

    let merged = runs(blocks(doc(split)).first)
    #expect(merged.map(\.text) == ["한 문장", "굵게"])
}

@Test func mentionAndEmojiAndInlineCardBecomeReadableText() {
    let rendered = blocks(doc(para(
        ADFNode(type: "mention", attrs: ["text": "@이름"]),
        text(" "),
        ADFNode(type: "emoji", attrs: ["text": "👍", "shortName": ":+1:"]),
        text(" "),
        ADFNode(type: "inlineCard",
                attrs: ["url": "https://example.atlassian.net/browse/DEMO-1"])
    )))

    #expect(plain(rendered) == "@이름 👍 https://example.atlassian.net/browse/DEMO-1")
    // 인라인 카드는 주소를 그대로 적되 누를 수 있어야 한다 — 그러라고 있는 노드다.
    #expect(runs(rendered.first).last?.link != nil)
}

/// emoji에 text가 없으면 shortName으로 떨어진다. 아무것도 안 그리면 문장에 구멍이 생긴다.
@Test func emojiFallsBackToShortName() {
    let rendered = blocks(doc(para(ADFNode(type: "emoji", attrs: ["shortName": ":tada:"]))))

    #expect(plain(rendered) == ":tada:")
}

/// Jira의 상태 알약은 색이 뜻을 나르지만 그 색을 쓸 수 없다. 대괄호로 감싸
/// 문장 안에서 구분되게 한다.
@Test func aStatusLozengeKeepsItsTextInBrackets() {
    let rendered = blocks(doc(para(ADFNode(type: "status", attrs: ["text": "완료"]))))

    #expect(plain(rendered) == "[완료]")
}
