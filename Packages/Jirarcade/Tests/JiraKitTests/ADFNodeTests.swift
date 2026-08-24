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
@Test func nonStringAttrsAreDroppedNotFatal() throws {
    let json = #"""
    {"type":"doc","content":[
      {"type":"mediaSingle","attrs":{"layout":"center","width":80.5},"content":[]}
    ]}
    """#

    let doc = try ADFNode.decode(Data(json.utf8))

    #expect(doc.content[0].attrs["layout"] == "center")
    #expect(doc.content[0].attrs["width"] == nil)
}

/// marks의 **존재 여부**만 기억한다. 굵게·링크를 평문으로 왕복시킬 수 없다는 판단은
/// 본문 편집을 여는 다음 단계가 이 값을 보고 내린다.
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
