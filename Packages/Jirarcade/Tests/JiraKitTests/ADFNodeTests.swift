import Testing
import Foundation
@testable import JiraKit

@Test func parsesNestedContentAndKeepsStringAttrs() throws {
    let json = #"""
    {"type":"doc","version":1,"content":[
      {"type":"paragraph","content":[
        {"type":"text","text":"안녕"},
        {"type":"mention","attrs":{"id":"abc","text":"@이름"}}
      ]}
    ]}
    """#

    let doc = try ADFNode.decode(Data(json.utf8))

    #expect(doc.type == "doc")
    #expect(doc.content.count == 1)
    #expect(doc.content[0].content.count == 2)
    #expect(doc.content[0].content[0].text == "안녕")
    #expect(doc.content[0].content[1].attrs["text"] == "@이름")
}

/// attrs에는 문자열이 아닌 값도 섞여 온다(`width`는 숫자, `layout`은 문자열).
/// 숫자 하나 때문에 문단 전체가 디코딩 실패하면 본문이 통째로 사라진다.
///
/// 스칼라는 전부 문자열로 눕혀 **남긴다.** 예전에는 숫자를 버렸는데, 그러면 제목의
/// `level`처럼 숫자로만 오는 값이 통째로 사라져 제목이 몇 단계인지 알 수 없었다.
@Test func scalarAttrsSurviveAsStringsAndOthersAreDroppedNotFatal() throws {
    let json = #"""
    {"type":"doc","content":[
      {"type":"mediaSingle",
       "attrs":{"layout":"center","width":80.5,"level":3,"isNumberColumnEnabled":true,
                "nested":{"a":1}},
       "content":[]}
    ]}
    """#

    let doc = try ADFNode.decode(Data(json.utf8))
    let attrs = doc.content[0].attrs

    #expect(attrs["layout"] == "center")
    #expect(attrs["width"] == "80.5")
    // 정수로 떨어지는 값은 정수로 적는다 — 읽는 쪽이 `Int(...)`로 되돌리기 때문이다.
    #expect(attrs["level"] == "3")
    #expect(Int(attrs["level"] ?? "") == 3)
    #expect(attrs["isNumberColumnEnabled"] == "true")
    // 객체는 문자열 하나로 눕힐 수 없다. 버리되 다른 속성을 데려가지 않는다.
    #expect(attrs["nested"] == nil)
}

/// marks의 **존재 여부**를 값과 따로 기억한다. 굵게·링크를 평문으로 왕복시킬 수
/// 없다는 판단은 본문 편집을 여는 다음 단계가 `hasMarks`를 보고 내린다.
@Test func recordsWhetherAnyMarkIsPresent() throws {
    let json = #"""
    {"type":"doc","content":[
      {"type":"paragraph","content":[
        {"type":"text","text":"굵게","marks":[{"type":"strong"}]},
        {"type":"text","text":"보통"}
      ]}
    ]}
    """#

    let doc = try ADFNode.decode(Data(json.utf8))

    #expect(doc.content[0].content[0].hasMarks)
    #expect(!doc.content[0].content[1].hasMarks)
}

/// 서식의 **값**도 남긴다. 링크는 `href`가 없으면 어디로 가는지 그릴 수 없다.
@Test func marksCarryTheirValues() throws {
    let json = #"""
    {"type":"doc","content":[
      {"type":"paragraph","content":[
        {"type":"text","text":"문서","marks":[
          {"type":"strong"},
          {"type":"link","attrs":{"href":"https://example.atlassian.net/browse/DEMO-1"}}
        ]}
      ]}
    ]}
    """#

    let doc = try ADFNode.decode(Data(json.utf8))
    let run = doc.content[0].content[0]

    #expect(run.marks.map(\.type) == ["strong", "link"])
    #expect(run.marks[1].attrs["href"] == "https://example.atlassian.net/browse/DEMO-1")
}

/// 서식 하나가 깨져도 같은 텍스트의 나머지 서식은 살아남는다. 링크 하나를 못 읽었다고
/// 굵게까지 잃을 이유가 없다.
@Test func aMalformedMarkDoesNotEraseItsSiblings() throws {
    let json = #"""
    {"type":"doc","content":[
      {"type":"paragraph","content":[
        {"type":"text","text":"굵게","marks":[{"noType":true},{"type":"strong"}]}
      ]}
    ]}
    """#

    let doc = try ADFNode.decode(Data(json.utf8))
    let run = doc.content[0].content[0]

    #expect(run.marks.map(\.type) == ["strong"])
    // 읽어낸 서식이 하나뿐이어도 "서식이 있었다"는 사실은 그대로다 — 편집 게이트는
    // 이 사실을 봐야 모르는 서식을 통과시키지 않는다.
    #expect(run.hasMarks)
}

/// `marks: []`는 "서식 키가 있었다"이지 "서식이 있었다"가 아니다. 두 값이 이 경우를
/// 다르게 답해야, 편집 게이트가 보수적인 쪽(=편집을 열지 않음)에 선다.
@Test func anEmptyMarksArrayStillCountsAsPresent() throws {
    let json = #"""
    {"type":"doc","content":[
      {"type":"paragraph","content":[{"type":"text","text":"평문","marks":[]}]}
    ]}
    """#

    let doc = try ADFNode.decode(Data(json.utf8))
    let run = doc.content[0].content[0]

    #expect(run.marks.isEmpty)
    #expect(run.hasMarks)
}

/// 배열 원소 하나가 디코딩에 실패해도 다른 형제 노드는 보존된다.
/// 하나 깨진 원소가 있어도 그 배열 전체를 버리면 안 된다.
@Test func malformedChildDoesNotEraseValidSiblings() throws {
    let json = #"""
    {"type":"paragraph","content":[
      {"type":"text","text":"good"},
      {"content":[]},
      {"type":"text","text":"also good"}
    ]}
    """#

    let para = try ADFNode.decode(Data(json.utf8))

    #expect(para.content.count == 2)
    #expect(para.content[0].type == "text")
    #expect(para.content[0].text == "good")
    #expect(para.content[1].type == "text")
    #expect(para.content[1].text == "also good")
}
