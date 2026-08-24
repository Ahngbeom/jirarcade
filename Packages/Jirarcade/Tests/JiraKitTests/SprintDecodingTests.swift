import Testing
import Foundation
@testable import JiraKit

private let threeSprints = """
[
  {"id":3342,"name":"DEMO 스프린트 (56)","state":"closed",
   "startDate":"2026-05-21T10:00:36.705Z","endDate":"2026-05-28T10:00:00.000Z"},
  {"id":3208,"name":"DEMO 스프린트 (52)","state":"closed",
   "startDate":"2026-03-19T10:00:31.942Z","endDate":"2026-04-02T10:00:00.000Z"},
  {"id":3518,"name":"DEMO 스프린트 (66)","state":"future",
   "startDate":"2026-08-06T10:00:13.000Z","endDate":"2026-08-13T10:00:00.000Z"}
]
"""

@Test func decodesTheFieldsTheAppUses() throws {
    let sprints = try JiraSprint.decodeList(Data(threeSprints.utf8))

    #expect(sprints.count == 3)
    #expect(sprints[0].id == 3342)
    #expect(sprints[0].name == "DEMO 스프린트 (56)")
    #expect(sprints[0].state == "closed")
    #expect(sprints[2].state == "future")
}

/// 실측 응답은 밀리초와 `Z`를 함께 쓴다. 이 형식을 못 읽으면 정렬 키가 통째로 nil이 된다.
@Test func parsesTheTimestampFormatJiraActuallySends() throws {
    let sprints = try JiraSprint.decodeList(Data(threeSprints.utf8))

    let earliest = try #require(sprints[1].startDate)
    let latest = try #require(sprints[0].startDate)
    #expect(earliest < latest)
}

/// `startDate`가 없는 스프린트가 드물게 있다. 그 원소만 nil이고 나머지는 살아야 한다.
@Test func toleratesAMissingStartDate() throws {
    let body = """
    [{"id":1,"name":"DEMO 스프린트 (1)","state":"future"}]
    """

    let sprints = try JiraSprint.decodeList(Data(body.utf8))

    #expect(sprints.count == 1)
    #expect(sprints[0].startDate == nil)
}

/// 원소 하나가 깨져도 배열 전체를 버리지 않는다 — `JiraSearchResponse`가 이슈 단위로
/// 이미 쓰는 방식이다. 스프린트 하나 때문에 티켓의 이월 정보를 전부 잃으면 안 된다.
@Test func skipsABrokenElementRatherThanFailingTheWholeArray() throws {
    let body = """
    [
      {"id":1,"name":"DEMO 스프린트 (1)","state":"closed","startDate":"2026-05-21T10:00:00.000Z"},
      {"id":"not-a-number","name":"깨진 것","state":"closed"},
      {"id":3,"name":"DEMO 스프린트 (3)","state":"future","startDate":"2026-06-01T10:00:00.000Z"}
    ]
    """

    let sprints = try JiraSprint.decodeList(Data(body.utf8))

    #expect(sprints.map(\.id) == [1, 3])
}

@Test func handlesAnEmptyArray() throws {
    #expect(try JiraSprint.decodeList(Data("[]".utf8)).isEmpty)
}

/// **필드는 이름이 아니라 스키마로 찾는다.** 실측 사이트의 필드 이름은 "Sprint"가 아니라
/// "스프린트"였다 — 이름으로 찾는 구현은 영어 사이트에서만 돌고 다른 로케일에서 조용히 실패한다.
@Test func findsTheSprintFieldBySchemaNotByName() throws {
    let body = """
    [
      {"id":"summary","name":"Summary","schema":{"type":"string"}},
      {"id":"customfield_10020","name":"스프린트",
       "schema":{"type":"array","items":"json","custom":"com.pyxis.greenhopper.jira:gh-sprint"}},
      {"id":"customfield_10001","name":"Sprint Backlog",
       "schema":{"type":"string","custom":"com.example:something-else"}}
    ]
    """

    #expect(try JiraFieldCatalog.sprintFieldID(in: Data(body.utf8)) == "customfield_10020")
}

/// 스프린트를 쓰지 않는 사이트에는 그 필드가 없다. 오류가 아니라 사실이다.
@Test func returnsNilWhenTheSiteHasNoSprintField() throws {
    let body = """
    [{"id":"summary","name":"Summary","schema":{"type":"string"}}]
    """

    #expect(try JiraFieldCatalog.sprintFieldID(in: Data(body.utf8)) == nil)
}

/// 스키마가 없는 필드(시스템 필드 일부)가 섞여도 넘어가야 한다.
@Test func ignoresFieldsWithoutASchema() throws {
    let body = """
    [
      {"id":"thumbnail","name":"Thumbnail"},
      {"id":"customfield_10020","name":"스프린트",
       "schema":{"type":"array","custom":"com.pyxis.greenhopper.jira:gh-sprint"}}
    ]
    """

    #expect(try JiraFieldCatalog.sprintFieldID(in: Data(body.utf8)) == "customfield_10020")
}
