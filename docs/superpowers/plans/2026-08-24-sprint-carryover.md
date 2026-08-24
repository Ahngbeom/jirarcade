# 스프린트 이월 표시 (계획 2b-3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 티켓이 몇 번이나 다음 스프린트로 미뤄졌는지를 퀘스트 보드 카드에 표시한다.

**Architecture:** 스프린트 정보는 이미 `/search/jql` 응답에 배열로 오므로 Agile API도 `AuthProvider` 계약 변경도 필요 없다. 로그인 시 `/field`에서 스프린트 필드 ID를 한 번 찾아 저장하고(이름이 아니라 `schema.custom`으로 식별), 동기화 때 그 필드를 함께 요청해 이월 횟수와 양 끝 스프린트 이름을 미러에 담는다. 계산은 `ArcadeCore`의 순수 함수, 표시는 뷰가 조립한다. **채점에는 일절 반영하지 않는다.**

**Tech Stack:** Swift 6.2 / SwiftUI / SwiftData / Swift Testing

**Spec:** `docs/superpowers/specs/2026-08-24-sprint-carryover-design.md`
**선행 스펙:** `docs/superpowers/specs/2026-08-12-jirarcade-design.md` (v0.1) · `docs/superpowers/specs/2026-08-21-quest-board-design.md` (퀘스트 보드)

## Global Constraints

- 스펙 원본은 위 세 문서다. 충돌 시 스프린트 이월 스펙(2026-08-24)이 우선한다.
- 모듈 의존 방향은 단방향이다: `ArcadeUI → ArcadeApp → ArcadeCore → JiraKit`. 역방향 import 금지.
- **`ArcadeApp`은 SwiftUI를 import하지 않는다.** `ModuleBoundaryTests.arcadeAppNeverImportsSwiftUI`가 강제한다.
- **`ArcadeUI`의 뷰 코드에 색 리터럴을 두지 않는다.** 모든 색은 `@Environment(\.arcadeTheme)`에서 온다.
- **뷰는 `Date()`·`Calendar.current`·`RuleSet.default`를 직접 부르지 않는다.** 현재 `Sources/ArcadeUI/` 아래 이 셋의 출현 횟수는 **0이며 그대로 유지한다.**
- **`ArcadeCore`는 화면을 모른다.** 사실(숫자·이름)만 담고 문장·표기·강조 기준은 뷰가 정한다. `DueState`와 `HygieneNextStep`이 이미 그 경계다.
- **채점 결과가 이 계획 전후로 동일해야 한다.** 이월은 표시 전용이며 `XpAwarder`·`HygieneCalculator`·`ScoreEngine`·`AbuseGuard` 어디에도 들어가지 않는다.
- Jira 응답 본문 조각이 화면·로그·저장소에 닿지 않는다.
- 조직 특정 정보를 코드·테스트에 넣지 않는다. 테스트는 `example.atlassian.net`, `DEMO-`를 쓴다. **스프린트 이름 픽스처도 `DEMO 스프린트 (1)`처럼 조직명 없이 적는다.**
- 테스트는 Swift Testing(`@Test` / `#expect`)을 쓴다.
- 정렬은 결정적이어야 한다 — 동률 타이브레이크를 명시한다.
- 각 태스크는 `swift test` 통과 후 커밋으로 끝난다.

## File Structure

```
Packages/Jirarcade/
├── Sources/
│   ├── JiraKit/
│   │   ├── SprintDTO.swift              ← 신규. JiraSprint + 필드 카탈로그 항목
│   │   ├── DTO.swift                    ← 수정. JiraIssue가 스프린트 배열을 담는다
│   │   └── JiraClient.swift             ← 수정. fields() 조회 추가
│   ├── ArcadeCore/
│   │   ├── Domain/
│   │   │   ├── SprintHistory.swift      ← 신규. 이월 횟수 + 양 끝 이름
│   │   │   └── ObservedIssue.swift      ← 수정. 세 값 추가
│   │   ├── Store/StoreModels.swift      ← 수정. IssueSnapshot 세 컬럼 (기본값 필수)
│   │   ├── Store/ArcadeStore.swift      ← 수정. 미러 저장/복원에 세 값
│   │   ├── Sync/SyncEngine.swift        ← 수정. 요청 필드에 스프린트 필드 ID
│   │   └── Board/BoardLayout.swift      ← 수정. BoardSlot에 세 값 전달
│   ├── ArcadeApp/
│   │   ├── SprintFieldStore.swift       ← 신규. 필드 ID 저장 (WorkflowStore와 별개)
│   │   └── AppModel.swift               ← 수정. 로그인 시 조회, 동기화에 전달
│   └── ArcadeUI/QuestBoard/
│       └── TicketCardView.swift         ← 수정. 이월 줄과 툴팁
└── Tests/
    ├── JiraKitTests/SprintDecodingTests.swift       ← 신규
    ├── ArcadeCoreTests/SprintHistoryTests.swift     ← 신규
    └── ArcadeAppTests/SprintFieldStoreTests.swift   ← 신규
```

`SprintFieldStore`를 `WorkflowStore`에 얹지 않는 이유는 스펙 §3에 있다 — 그 프로토콜은 이미 사용자 매핑과 백필 폴백을 함께 떠안고 있고, history-backfill 후속 항목 §5.9가 "구현이 늘면 별도 프로토콜로 쪼개는 편이 낫다"고 지적해 두었다.

---

### Task 1: `JiraSprint` 디코딩과 필드 카탈로그

스프린트 배열을 값 타입으로 옮기고, `/field` 응답에서 스프린트 필드를 **이름이 아니라 스키마로** 찾는다.

**Files:**
- Create: `Packages/Jirarcade/Sources/JiraKit/SprintDTO.swift`
- Test: `Packages/Jirarcade/Tests/JiraKitTests/SprintDecodingTests.swift`

**Interfaces:**
- Produces:
  - `struct JiraSprint: Sendable, Equatable, Decodable { id: Int; name: String; state: String; startDate: Date? }`
  - `JiraSprint.decodeList(_ data: Data) throws -> [JiraSprint]` — 배열 원소 하나가 깨져도 나머지를 살린다
  - `enum JiraFieldCatalog { static func sprintFieldID(in data: Data) throws -> String? }`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Packages/Jirarcade/Tests/JiraKitTests/SprintDecodingTests.swift`:

```swift
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
    #expect(earliest < #require(sprints[0].startDate))
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
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter SprintDecoding
```

기대: 컴파일 실패 — `cannot find 'JiraSprint' in scope`

- [ ] **Step 3: 최소 구현을 쓴다**

`Packages/Jirarcade/Sources/JiraKit/SprintDTO.swift`:

```swift
import Foundation

/// 티켓이 속한 스프린트 하나.
///
/// 응답에는 `boardId`·`goal`·`endDate`·`completeDate`도 오지만 담지 않는다 — 실측에서
/// `goal`은 전부 빈 문자열이었고 나머지는 이 계획이 쓰지 않는다.
public struct JiraSprint: Sendable, Equatable {
    public let id: Int
    public let name: String
    /// `closed` / `future` / `active`. 이월 계산은 구분하지 않지만
    /// 나중에 필요할 값이라 담는다.
    public let state: String
    /// 정렬 키. 드물게 없다.
    public let startDate: Date?

    public init(id: Int, name: String, state: String, startDate: Date?) {
        self.id = id
        self.name = name
        self.state = state
        self.startDate = startDate
    }
}

extension JiraSprint: Decodable {
    private enum CodingKeys: String, CodingKey { case id, name, state, startDate }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        state = try container.decode(String.self, forKey: .state)
        if let raw = try container.decodeIfPresent(String.self, forKey: .startDate) {
            startDate = JiraSprint.parseTimestamp(raw)
        } else {
            startDate = nil
        }
    }

    /// 원소 하나가 깨져도 배열 전체를 버리지 않는다.
    /// `JiraSearchResponse`가 이슈 단위로 이미 쓰는 방식이다 — 스프린트 하나 때문에
    /// 그 티켓의 이월 정보를 통째로 잃으면 안 된다.
    public static func decodeList(_ data: Data) throws -> [JiraSprint] {
        struct Failable: Decodable {
            let value: JiraSprint?
            init(from decoder: any Decoder) throws {
                value = try? JiraSprint(from: decoder)
            }
        }
        return try JSONDecoder().decode([Failable].self, from: data).compactMap(\.value)
    }

    /// `.withFractionalSeconds`가 켜진 포매터는 소수점이 **없으면 nil을 돌려준다**.
    /// Jira는 보통 `.000`을 붙이지만 배포·프록시에 따라 빠질 수 있어 두 포매터를 순서대로 쓴다.
    /// `JiraSearchResponse`가 `updated`에 쓰는 것과 같은 이유다.
    nonisolated(unsafe) static let timestampFormatters: [ISO8601DateFormatter] = {
        let variants: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ]
        return variants.map { options in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            return formatter
        }
    }()

    static func parseTimestamp(_ text: String) -> Date? {
        for formatter in timestampFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// `/rest/api/3/field` 응답에서 스프린트 필드를 찾는다.
public enum JiraFieldCatalog {
    /// Greenhopper 시절부터 유지돼 온 스프린트 필드의 스키마 식별자.
    /// **로케일과 무관하다** — 이것으로 찾는 이유가 그것이다.
    static let sprintSchema = "com.pyxis.greenhopper.jira:gh-sprint"

    /// 스프린트 필드의 커스텀 필드 ID. 없으면 nil.
    ///
    /// **이름으로 찾지 않는다.** 실측 사이트의 필드 이름은 `"Sprint"`가 아니라 `"스프린트"`였다.
    /// 이름은 사이트 로케일을 따르므로, 이름 비교는 영어 사이트에서만 동작하고 다른 곳에서는
    /// 아무것도 찾지 못한 채 조용히 지나간다.
    public static func sprintFieldID(in data: Data) throws -> String? {
        struct Entry: Decodable {
            let id: String
            let schema: Schema?
            struct Schema: Decodable { let custom: String? }
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return entries.first { $0.schema?.custom == sprintSchema }?.id
    }
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter SprintDecoding
```

기대: 8 tests PASS

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/JiraKit/SprintDTO.swift \
        Packages/Jirarcade/Tests/JiraKitTests/SprintDecodingTests.swift
git commit -m "feat: 스프린트 배열 디코딩과 스키마 기반 필드 식별

필드를 이름이 아니라 schema.custom으로 찾는다. 실측 사이트의 필드 이름이
'Sprint'가 아니라 '스프린트'였다 — 이름 비교는 영어 사이트에서만 돌고
다른 로케일에서는 조용히 아무것도 찾지 못한다.

원소 하나가 깨져도 배열 전체를 버리지 않는다. JiraSearchResponse가 이슈
단위로 이미 쓰는 방식이며, 스프린트 하나 때문에 그 티켓의 이월 정보를
통째로 잃을 이유가 없다."
```

---

### Task 2: `SprintHistory` — 이월 횟수와 양 끝 이름

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Domain/SprintHistory.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/SprintHistoryTests.swift`

**Interfaces:**
- Consumes: `JiraSprint` (Task 1)
- Produces:
  - `struct SprintSummary: Sendable, Equatable { carryOvers: Int; firstName: String?; latestName: String? }`
  - `SprintHistory.summarize(_ sprints: [JiraSprint]) -> SprintSummary`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Packages/Jirarcade/Tests/ArcadeCoreTests/SprintHistoryTests.swift`:

```swift
import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

private func sprint(_ id: Int, _ name: String, day: Int?, state: String = "closed") -> JiraSprint {
    JiraSprint(
        id: id, name: name, state: state,
        startDate: day.map { iso("2026-05-\(String(format: "%02d", $0))T10:00:00Z") }
    )
}

/// 실측에서 배열이 [56, 57, 55, 64, 63, 52, 65, ...] 순으로 왔다.
/// startDate로 정렬하지 않으면 양 끝 이름이 엉뚱해진다.
@Test func sortsByStartDateBecauseTheArrayArrivesShuffled() {
    let summary = SprintHistory.summarize([
        sprint(2, "DEMO 스프린트 (2)", day: 21),
        sprint(3, "DEMO 스프린트 (3)", day: 28),
        sprint(1, "DEMO 스프린트 (1)", day: 14),
    ])

    #expect(summary.firstName == "DEMO 스프린트 (1)")
    #expect(summary.latestName == "DEMO 스프린트 (3)")
}

/// 첫 스프린트는 이월이 아니다. 3개에 속했으면 2번 미뤄진 것이다.
@Test func countsCarryOversAsSprintsMinusOne() {
    let summary = SprintHistory.summarize([
        sprint(1, "DEMO 스프린트 (1)", day: 14),
        sprint(2, "DEMO 스프린트 (2)", day: 21),
        sprint(3, "DEMO 스프린트 (3)", day: 28),
    ])

    #expect(summary.carryOvers == 2)
}

@Test func reportsZeroForASingleSprint() {
    let summary = SprintHistory.summarize([sprint(1, "DEMO 스프린트 (1)", day: 14)])

    #expect(summary.carryOvers == 0)
    #expect(summary.firstName == "DEMO 스프린트 (1)")
    #expect(summary.latestName == "DEMO 스프린트 (1)")
}

@Test func reportsNothingForNoSprints() {
    let summary = SprintHistory.summarize([])

    #expect(summary.carryOvers == 0)
    #expect(summary.firstName == nil)
    #expect(summary.latestName == nil)
}

/// `startDate`가 없는 스프린트는 정렬에서 맨 뒤로 보내되 **횟수에는 들어간다** —
/// 그 스프린트에 속했다는 사실은 날짜를 모른다고 사라지지 않는다.
@Test func keepsUndatedSprintsInTheCountAndSortsThemLast() {
    let summary = SprintHistory.summarize([
        sprint(9, "DEMO 스프린트 (9)", day: nil),
        sprint(1, "DEMO 스프린트 (1)", day: 14),
    ])

    #expect(summary.carryOvers == 1)
    #expect(summary.firstName == "DEMO 스프린트 (1)")
    #expect(summary.latestName == "DEMO 스프린트 (9)")
}

/// Swift의 `sorted(by:)`는 안정 정렬이 아니다. 같은 날 시작한 스프린트 둘이 있으면
/// 타이브레이크가 없을 때 툴팁이 실행마다 바뀐다.
@Test func breaksStartDateTiesByID() {
    let summary = SprintHistory.summarize([
        sprint(20, "DEMO 스프린트 (20)", day: 14),
        sprint(10, "DEMO 스프린트 (10)", day: 14),
    ])

    #expect(summary.firstName == "DEMO 스프린트 (10)")
    #expect(summary.latestName == "DEMO 스프린트 (20)")
}

/// 예정 스프린트도 이월로 센다 — 다음에 하기로 올려둔 것 역시 "아직 안 끝났다"이다.
@Test func countsFutureSprintsToo() {
    let summary = SprintHistory.summarize([
        sprint(1, "DEMO 스프린트 (1)", day: 14, state: "closed"),
        sprint(2, "DEMO 스프린트 (2)", day: 21, state: "future"),
    ])

    #expect(summary.carryOvers == 1)
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter SprintHistory
```

기대: 컴파일 실패 — `cannot find 'SprintHistory' in scope`

- [ ] **Step 3: 최소 구현을 쓴다**

`Packages/Jirarcade/Sources/ArcadeCore/Domain/SprintHistory.swift`:

```swift
import Foundation
import JiraKit

/// 티켓의 스프린트 이력에서 화면이 쓰는 것만 뽑은 요약.
///
/// **문장을 담지 않는다.** `"A → B"` 같은 표현은 뷰가 만든다 — `DueState`·`HygieneNextStep`과
/// 같은 경계다. `ArcadeCore`가 문자열을 만들면 그 모듈이 화면을 알게 된다.
public struct SprintSummary: Sendable, Equatable {
    /// 거쳐 온 스프린트 수 - 1. 0개나 1개면 0이다.
    public let carryOvers: Int
    /// 가장 이른 스프린트 이름.
    public let firstName: String?
    /// 가장 늦은 스프린트 이름.
    public let latestName: String?

    public init(carryOvers: Int, firstName: String?, latestName: String?) {
        self.carryOvers = carryOvers
        self.firstName = firstName
        self.latestName = latestName
    }

    public static let none = SprintSummary(carryOvers: 0, firstName: nil, latestName: nil)
}

public enum SprintHistory {
    /// 스프린트 배열에서 이월 횟수와 양 끝 이름을 뽑는다.
    ///
    /// **배열은 시간순이 아니다.** 실측에서 `[56, 57, 55, 64, 63, 52, 65, 62, 60, 61, 59, 58, 66]`
    /// 순으로 왔다. `startDate`로 정렬해야 첫·마지막이 맞는다.
    ///
    /// `state`는 구분하지 않는다 — 예정 스프린트에 올라가 있다는 것도 "아직 안 끝났다"는
    /// 같은 이야기다.
    public static func summarize(_ sprints: [JiraSprint]) -> SprintSummary {
        guard !sprints.isEmpty else { return .none }

        // `startDate`가 없는 것은 맨 뒤로 보내되 버리지 않는다 — 그 스프린트에 속했다는
        // 사실은 날짜를 모른다고 사라지지 않으므로 횟수에는 들어가야 한다.
        //
        // 동률을 `id`로 가르는 이유: Swift의 `sorted(by:)`는 안정 정렬이 아니라, 같은 날
        // 시작한 스프린트 둘이 있으면 툴팁의 양 끝이 실행마다 뒤집힌다.
        let ordered = sprints.sorted { left, right in
            switch (left.startDate, right.startDate) {
            case let (l?, r?): return l == r ? left.id < right.id : l < r
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return left.id < right.id
            }
        }

        return SprintSummary(
            carryOvers: ordered.count - 1,
            firstName: ordered.first?.name,
            latestName: ordered.last?.name
        )
    }
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter SprintHistory
```

기대: 7 tests PASS

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Domain/SprintHistory.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/SprintHistoryTests.swift
git commit -m "feat: 스프린트 이력에서 이월 횟수와 양 끝 이름을 뽑는다

배열이 시간순으로 오지 않는다 — 실측에서 [56, 57, 55, 64, 63, 52, ...] 순이었다.
startDate로 정렬하고 동률은 id로 가른다. Swift의 sorted(by:)는 안정 정렬이
아니라 같은 날 시작한 스프린트 둘이 있으면 툴팁이 실행마다 뒤집힌다.

startDate가 없는 스프린트는 맨 뒤로 보내되 횟수에는 넣는다 — 그 스프린트에
속했다는 사실은 날짜를 모른다고 사라지지 않는다."
```

---
### Task 3: 필드 목록 조회와 `JiraIssue`에 스프린트 싣기

스프린트 필드 키는 사이트마다 다르므로 **고정 `CodingKeys`로 잡을 수 없다.** 디코딩 시점에
필드 ID를 넘겨 동적 키로 읽는다.

**Files:**
- Modify: `Packages/Jirarcade/Sources/JiraKit/SprintDTO.swift` (`Failable`을 파일 스코프로)
- Modify: `Packages/Jirarcade/Sources/JiraKit/DTO.swift` (`JiraIssue.sprints`, 동적 키, `decode` 시그니처)
- Modify: `Packages/Jirarcade/Sources/JiraKit/JiraClient.swift` (`fields()`, `searchIssues`에 필드 ID)
- Test: `Packages/Jirarcade/Tests/JiraKitTests/SprintDecodingTests.swift` (덧붙임)

**Interfaces:**
- Consumes: `JiraSprint`, `JiraFieldCatalog.sprintFieldID(in:)` (Task 1)
- Produces:
  - `JiraIssue.sprints: [JiraSprint]` — 필드 ID를 안 넘겼거나 값이 없으면 빈 배열
  - `JiraSearchResponse.decode(_ data: Data, sprintFieldID: String?) throws -> IssuePage`
  - `JiraClient.fields() async throws -> Data` — `/field` 원본 바이트
  - `JiraClient.searchIssues(jql:fields:maxResults:pageToken:sprintFieldID:)`

- [ ] **Step 1: 실패하는 테스트를 덧붙인다**

`SprintDecodingTests.swift` 끝에 추가한다:

```swift
private func searchBody(sprintFieldKey: String, sprintJSON: String) -> String {
    """
    {"issues":[{"key":"DEMO-1","fields":{
      "summary":"a","status":{"name":"In Progress"},"issuetype":{"name":"Task"},
      "updated":"2026-08-14T09:00:00.000+0000",
      "\(sprintFieldKey)":\(sprintJSON)
    }}]}
    """
}

/// 필드 키는 사이트마다 다르다. 디코딩 시점에 넘긴 키로 읽는다.
@Test func readsSprintsFromTheFieldKeyItIsGiven() throws {
    let body = searchBody(sprintFieldKey: "customfield_10020", sprintJSON: """
    [{"id":1,"name":"DEMO 스프린트 (1)","state":"closed","startDate":"2026-05-14T10:00:00.000Z"},
     {"id":2,"name":"DEMO 스프린트 (2)","state":"future","startDate":"2026-05-21T10:00:00.000Z"}]
    """)

    let page = try JiraSearchResponse.decode(Data(body.utf8), sprintFieldID: "customfield_10020")

    #expect(page.issues.count == 1)
    #expect(page.issues[0].sprints.map(\.id) == [1, 2])
}

/// 다른 사이트의 키를 넘기면 그 필드가 없으므로 빈 배열이다 — 오류가 아니다.
@Test func yieldsNoSprintsWhenTheKeyDoesNotMatch() throws {
    let body = searchBody(sprintFieldKey: "customfield_10020", sprintJSON: "[]")

    let page = try JiraSearchResponse.decode(Data(body.utf8), sprintFieldID: "customfield_99999")

    #expect(page.issues[0].sprints.isEmpty)
}

/// 스프린트를 쓰지 않는 사이트에서는 필드 ID 자체가 nil이다.
@Test func yieldsNoSprintsWhenNoFieldIDIsKnown() throws {
    let body = searchBody(sprintFieldKey: "customfield_10020", sprintJSON: """
    [{"id":1,"name":"DEMO 스프린트 (1)","state":"closed","startDate":"2026-05-14T10:00:00.000Z"}]
    """)

    let page = try JiraSearchResponse.decode(Data(body.utf8), sprintFieldID: nil)

    #expect(page.issues[0].sprints.isEmpty)
}

/// 스프린트 필드가 `null`인 티켓이 흔하다(어느 스프린트에도 없는 티켓).
@Test func treatsANullSprintFieldAsNoSprints() throws {
    let body = searchBody(sprintFieldKey: "customfield_10020", sprintJSON: "null")

    let page = try JiraSearchResponse.decode(Data(body.utf8), sprintFieldID: "customfield_10020")

    #expect(page.issues[0].sprints.isEmpty)
}

/// 스프린트 원소 하나가 깨져도 그 **티켓 전체**를 잃으면 안 된다.
/// 티켓 단위 실패는 `IssuePage.failures`로 이미 다루지만, 스프린트는 부가 정보다.
@Test func keepsTheIssueWhenOneSprintElementIsBroken() throws {
    let body = searchBody(sprintFieldKey: "customfield_10020", sprintJSON: """
    [{"id":1,"name":"DEMO 스프린트 (1)","state":"closed","startDate":"2026-05-14T10:00:00.000Z"},
     {"id":"broken","name":"x","state":"closed"}]
    """)

    let page = try JiraSearchResponse.decode(Data(body.utf8), sprintFieldID: "customfield_10020")

    #expect(page.issues.count == 1)
    #expect(page.issues[0].sprints.map(\.id) == [1])
    #expect(page.failures.isEmpty)
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter SprintDecoding
```

기대: 컴파일 실패 — `extra argument 'sprintFieldID' in call`

- [ ] **Step 3: `Failable`을 파일 스코프로 올린다**

`SprintDTO.swift`의 `decodeList` 안에 있던 `Failable`을 파일 스코프로 옮겨 `DTO.swift`에서도
쓸 수 있게 한다:

```swift
/// 배열 원소 하나가 실패해도 나머지를 살리는 래퍼.
/// `JiraSearchResponse`가 이슈 단위로 쓰는 것과 같은 도구이며, 여기서는 스프린트 원소에 쓴다.
struct FailableSprint: Decodable {
    let value: JiraSprint?
    init(from decoder: any Decoder) throws {
        value = try? JiraSprint(from: decoder)
    }
}
```

`decodeList`는 그것을 쓰도록 줄인다:

```swift
    public static func decodeList(_ data: Data) throws -> [JiraSprint] {
        try JSONDecoder().decode([FailableSprint].self, from: data).compactMap(\.value)
    }
```

- [ ] **Step 4: `JiraIssue`에 스프린트를 싣는다**

`DTO.swift`의 `JiraIssue`에 프로퍼티와 init 파라미터를 더한다. **`init`의 기본값을 `[]`로 둔다** —
기존 호출부(테스트 픽스처 포함)가 그대로 컴파일된다:

```swift
    /// 이 티켓이 속한 스프린트. 필드 ID를 모르거나 값이 없으면 빈 배열이다.
    public let sprints: [JiraSprint]
```

```swift
    public init(
        key: String, summary: String, statusName: String, issueType: String,
        priority: String?, assigneeAccountId: String?, assigneeName: String?,
        dueDate: Date?, updated: Date, sprints: [JiraSprint] = []
    ) {
        // ...기존 대입 그대로...
        self.sprints = sprints
    }
```

`init(from:)`에 동적 키 읽기를 더한다. 필드 ID는 `userInfo`로 온다:

```swift
public extension CodingUserInfoKey {
    /// 스프린트 커스텀 필드의 키. 사이트마다 달라 고정 `CodingKeys`로 잡을 수 없으므로
    /// 디코딩 시점에 주입한다.
    static let sprintFieldID = CodingUserInfoKey(rawValue: "jirarcade.sprintFieldID")!
}

/// 런타임에 정해지는 필드 키를 읽기 위한 CodingKey.
private struct DynamicFieldKey: CodingKey {
    let stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}
```

`JiraIssue.init(from:)`의 `updated` 파싱 뒤에 넣는다:

```swift
        // 스프린트는 부가 정보다. 여기서 실패해도 티켓을 잃으면 안 되므로 전부 `try?`로 받는다.
        if let fieldID = decoder.userInfo[.sprintFieldID] as? String,
           let key = DynamicFieldKey(stringValue: fieldID),
           let dynamic = try? root.nestedContainer(keyedBy: DynamicFieldKey.self, forKey: .fields),
           let raw = try? dynamic.decodeIfPresent([FailableSprint].self, forKey: key) {
            sprints = raw.compactMap(\.value)
        } else {
            sprints = []
        }
```

- [ ] **Step 5: `JiraSearchResponse.decode`가 필드 ID를 받게 한다**

```swift
    public static func decode(_ data: Data, sprintFieldID: String? = nil) throws -> IssuePage {
        let decoder = JSONDecoder()
        if let sprintFieldID {
            decoder.userInfo[.sprintFieldID] = sprintFieldID
        }
        let envelope = try decoder.decode(Envelope.self, from: data)
        // ...이하 기존 본문 그대로...
    }
```

기본값 `nil` 덕분에 기존 호출부와 테스트가 그대로 컴파일된다.

- [ ] **Step 6: `JiraClient`에 `fields()`를 더하고 검색에 필드 ID를 넘긴다**

`statusCatalog()` 바로 아래에 같은 모양으로 넣는다:

```swift
    /// 사이트의 필드 목록 원본. 스프린트 필드 ID를 찾는 데 쓴다.
    ///
    /// 파싱을 `JiraFieldCatalog`에 맡기고 여기서는 바이트만 돌려주는 이유: 이 응답은 수백 개
    /// 항목이고 앱이 쓰는 것은 한 필드의 id 하나뿐이다. DTO로 전부 모델링할 값이 없다.
    public func fields() async throws -> Data {
        try await perform(method: "GET", path: "/field", body: nil, resource: "field")
    }
```

`searchIssues`에 파라미터를 더한다 (기본값 `nil`로 기존 호출부 보존):

```swift
    public func searchIssues(
        jql: String, fields: [String], maxResults: Int, pageToken: String?,
        sprintFieldID: String? = nil
    ) async throws -> IssuePage {
        // ...payload 구성 그대로...
        do {
            return try JiraSearchResponse.decode(data, sprintFieldID: sprintFieldID)
        } catch {
            throw JiraError.decoding(context: "search: \(error)")
        }
    }
```

- [ ] **Step 7: 테스트가 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter SprintDecoding
```

기대: 13 tests PASS

- [ ] **Step 8: 전체 테스트를 돌린다**

```bash
cd Packages/Jirarcade && swift test
```

기대: 전체 PASS. `JiraIssue`의 init에 기본값을 뒀으므로 기존 픽스처가 깨지지 않아야 한다.

- [ ] **Step 9: 커밋**

```bash
git add Packages/Jirarcade/Sources/JiraKit/ \
        Packages/Jirarcade/Tests/JiraKitTests/SprintDecodingTests.swift
git commit -m "feat: 동적 필드 키로 스프린트를 읽고 /field를 조회한다

스프린트 필드 키가 사이트마다 달라 고정 CodingKeys로 잡을 수 없다. 디코딩
시점에 userInfo로 키를 주입하고 DynamicFieldKey로 읽는다.

스프린트 디코딩 실패가 티켓을 잃게 하지 않는다 — 전부 try?로 받고 실패하면
빈 배열이다. 부가 정보 때문에 관측 자체를 놓치면 안 된다.

/field는 수백 항목인데 앱이 쓰는 것은 한 필드의 id 하나뿐이라 DTO로 모델링하지
않고 바이트를 그대로 넘겨 JiraFieldCatalog가 파싱한다."
```

---

### Task 4: 필드 ID 저장소와 미러 확장

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeApp/SprintFieldStore.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Domain/ObservedIssue.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Store/StoreModels.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Store/ArcadeStore.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/SprintFieldStoreTests.swift`

**Interfaces:**
- Consumes: `SprintSummary`, `SprintHistory.summarize(_:)` (Task 2), `JiraIssue.sprints` (Task 3)
- Produces:
  - `protocol SprintFieldStore: Sendable { func load() throws -> String?; func save(_ id: String) throws; func clear() throws }`
  - `FileSprintFieldStore` / `InMemorySprintFieldStore`
  - `ObservedIssue.sprintCarryOvers: Int`, `.firstSprintName: String?`, `.latestSprintName: String?`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Packages/Jirarcade/Tests/ArcadeAppTests/SprintFieldStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import ArcadeApp

@Test func remembersTheFieldIDAcrossLoads() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileSprintFieldStore(directory: directory)

    try store.save("customfield_10020")

    #expect(try FileSprintFieldStore(directory: directory).load() == "customfield_10020")
}

@Test func reportsNothingBeforeAnythingIsSaved() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(try FileSprintFieldStore(directory: directory).load() == nil)
}

/// 계정이 바뀌면 버린다 — 다른 테넌트의 필드 ID는 무의미하고, 남겨두면 그 사이트에
/// 존재하지 않는 필드를 계속 요청하게 된다.
@Test func forgetsTheFieldIDWhenCleared() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileSprintFieldStore(directory: directory)
    try store.save("customfield_10020")

    try store.clear()

    #expect(try store.load() == nil)
}

/// 저장한 적 없는 상태에서 지워도 오류가 아니다 — 로그아웃 경로가 항상 부르기 때문이다.
@Test func clearingWhenEmptyIsNotAnError() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileSprintFieldStore(directory: directory).clear()
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter SprintFieldStore
```

기대: 컴파일 실패 — `cannot find 'FileSprintFieldStore' in scope`

- [ ] **Step 3: 저장소를 만든다**

`Packages/Jirarcade/Sources/ArcadeApp/SprintFieldStore.swift`:

```swift
import Foundation

/// 스프린트 커스텀 필드의 ID를 기억한다.
///
/// `WorkflowStore`에 얹지 않는 이유: 그 프로토콜은 이미 사용자 매핑과 백필 폴백을 함께
/// 떠안고 있다. 스프린트 필드 ID는 그 둘과 아무 관계가 없으므로 처음부터 따로 둔다 —
/// 세 번째 관심사를 더하면 "구현이 늘 때마다 모든 구현체가 무관한 메서드를 채워야 한다"는
/// 부담이 실제로 생긴다.
public protocol SprintFieldStore: Sendable {
    func load() throws -> String?
    func save(_ id: String) throws
    /// 계정이 바뀔 때 부른다. 다른 테넌트의 필드 ID는 무의미하다.
    func clear() throws
}

/// 앱 지원 디렉터리의 JSON 파일. `FileWorkflowStore`와 같은 자리, 다른 파일이다.
public struct FileSprintFieldStore: SprintFieldStore {
    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("sprint-field.json") }

    public init(directory: URL) { self.directory = directory }

    /// 기본 위치: ~/Library/Application Support/Jirarcade/
    public static func applicationSupport() throws -> FileSprintFieldStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Jirarcade", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return FileSprintFieldStore(directory: base)
    }

    private struct Stored: Codable { let fieldID: String }

    public func load() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Stored.self, from: data).fieldID
    }

    public func save(_ id: String) throws {
        let data = try JSONEncoder().encode(Stored(fieldID: id))
        try data.write(to: fileURL, options: .atomic)
    }

    /// 파일이 없어도 오류가 아니다 — 로그아웃 경로가 저장 여부와 무관하게 부른다.
    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// 테스트용. `InMemoryWorkflowStore`와 같은 패턴이다.
public final class InMemorySprintFieldStore: SprintFieldStore, @unchecked Sendable {
    private var stored: String?
    private let lock = NSLock()

    public init(seeded: String? = nil) { self.stored = seeded }

    public func load() throws -> String? { lock.withLock { stored } }
    public func save(_ id: String) throws { lock.withLock { stored = id } }
    public func clear() throws { lock.withLock { stored = nil } }
}
```

- [ ] **Step 4: `ObservedIssue`에 세 값을 더한다**

`ObservedIssue.swift`에 프로퍼티를 더하고, `init`에 **기본값과 함께** 파라미터를 더한다:

```swift
    /// 이 티켓이 거쳐 온 스프린트 수 - 1. 스프린트가 없거나 하나뿐이면 0이다.
    /// **채점에 쓰지 않는다** — 표시 전용이다.
    public let sprintCarryOvers: Int
    /// 가장 이른 스프린트 이름. 뷰가 "A → B" 문장을 만들 때 쓴다.
    public let firstSprintName: String?
    /// 가장 늦은 스프린트 이름.
    public let latestSprintName: String?
```

```swift
    public init(
        key: String, summary: String, statusName: String, issueType: String,
        priority: String?, assigneeAccountId: String?, assigneeName: String?,
        dueDate: Date?, jiraUpdatedAt: Date,
        sprintCarryOvers: Int = 0,
        firstSprintName: String? = nil,
        latestSprintName: String? = nil
    ) {
        // ...기존 대입 그대로...
        self.sprintCarryOvers = sprintCarryOvers
        self.firstSprintName = firstSprintName
        self.latestSprintName = latestSprintName
    }
```

`JiraIssue`에서 옮기는 이니셜라이저가 스프린트를 요약한다:

```swift
    public init(_ jira: JiraIssue) {
        let sprints = SprintHistory.summarize(jira.sprints)
        self.init(
            key: jira.key, summary: jira.summary, statusName: jira.statusName,
            issueType: jira.issueType, priority: jira.priority,
            assigneeAccountId: jira.assigneeAccountId, assigneeName: jira.assigneeName,
            dueDate: jira.dueDate, jiraUpdatedAt: jira.updated,
            sprintCarryOvers: sprints.carryOvers,
            firstSprintName: sprints.firstName,
            latestSprintName: sprints.latestName
        )
    }
```

- [ ] **Step 5: `IssueSnapshot`에 세 컬럼을 더한다**

`StoreModels.swift`의 `IssueSnapshot`에 넣는다. **기본값은 프로퍼티 선언에 붙인다** —
`IssueEventRecord.origin`과 같은 이유로, SwiftData는 기존 로우를 복원할 때 커스텀 `init`을
부르지 않으므로 `init` 파라미터 기본값만으로는 이 컬럼이 없던 레코드를 열 수 없다:

```swift
    /// 스프린트 이월 횟수. **기본값이 선언에 있어야** 이 컬럼이 없던 기존 미러가 열린다.
    public var sprintCarryOvers: Int = 0
    public var firstSprintName: String?
    public var latestSprintName: String?
```

`init`에도 기본값과 함께 파라미터를 더한다:

```swift
        sprintCarryOvers: Int = 0,
        firstSprintName: String? = nil,
        latestSprintName: String? = nil
```

- [ ] **Step 6: `ArcadeStore`가 세 값을 오가게 한다**

`ArcadeStore.swift`에서 `IssueSnapshot`을 만드는 자리와 `ObservedIssue`로 되돌리는 자리
양쪽에 세 값을 넣는다. `rg -n 'IssueSnapshot\(' Packages/Jirarcade/Sources/ArcadeCore/Store/ArcadeStore.swift`
로 모든 생성 지점을 찾아 빠짐없이 반영할 것 — 하나라도 놓치면 그 경로로 저장된 티켓만
이월이 0으로 보인다.

미러를 갱신하는 경로(기존 스냅샷의 필드를 덮는 곳)도 함께 고친다.

- [ ] **Step 7: 테스트가 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter SprintFieldStore
```

기대: 4 tests PASS

- [ ] **Step 8: 전체 테스트와 기존 미러 마이그레이션을 확인한다**

```bash
cd Packages/Jirarcade && swift test
```

기대: 전체 PASS.

기존 미러가 있는 상태에서 열리는지는 실제 앱으로 확인한다 — 이미 동기화된 DB가 있는
상태에서 앱을 띄워 크래시 없이 보드가 뜨면 lightweight 마이그레이션이 된 것이다:

```bash
cd Packages/Jirarcade && ./scripts/../../../scripts/make-app.sh --open
```

(스크립트는 저장소 루트에 있다: `./scripts/make-app.sh --open`)

- [ ] **Step 9: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeApp/SprintFieldStore.swift \
        Packages/Jirarcade/Sources/ArcadeCore/Domain/ObservedIssue.swift \
        Packages/Jirarcade/Sources/ArcadeCore/Store/ \
        Packages/Jirarcade/Tests/ArcadeAppTests/SprintFieldStoreTests.swift
git commit -m "feat: 스프린트 필드 ID 저장소와 미러 확장

필드 ID를 WorkflowStore에 얹지 않고 별도 프로토콜로 둔다. 그 프로토콜은 이미
사용자 매핑과 백필 폴백을 함께 떠안고 있고 후속 항목 §5.9가 분리를 권했다 —
스프린트 필드 ID는 워크플로와 아무 관계가 없다.

IssueSnapshot의 새 컬럼은 기본값을 프로퍼티 선언에 붙인다. SwiftData가 기존
로우를 복원할 때 커스텀 init을 부르지 않으므로 init 파라미터 기본값만으로는
이 컬럼이 없던 레코드를 열 수 없다(IssueEventRecord.origin과 같은 이유)."
```

---
### Task 5: 동기화 경로 배선

로그인 때 필드 ID를 찾아 저장하고, 동기화 때 그 필드를 함께 요청한다.

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Sync/SyncEngine.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift`
- Modify: `Packages/Jirarcade/Tests/ArcadeAppTests/TestSupport.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/SprintFieldStoreTests.swift` (덧붙임)

**Interfaces:**
- Consumes: `JiraClient.fields()`, `JiraClient.searchIssues(..., sprintFieldID:)` (Task 3), `JiraFieldCatalog.sprintFieldID(in:)` (Task 1), `SprintFieldStore` (Task 4)
- Produces: `AppModel`이 로그인 시 필드 ID를 확보하고 `IssueSource`가 그것을 써서 검색한다

- [ ] **Step 1: 실패하는 테스트를 덧붙인다**

`SprintFieldStoreTests.swift` 끝에 추가한다:

```swift
import ArcadeCore
import JiraKit

private let fieldsBody = """
[{"id":"customfield_10020","name":"스프린트",
  "schema":{"type":"array","custom":"com.pyxis.greenhopper.jira:gh-sprint"}}]
"""

/// `demoWorkflow`는 `ArcadeCoreTests`의 파일 스코프 픽스처라 이 타깃에서 보이지 않는다.
/// 이 테스트들이 매핑에서 필요한 것은 "마법사로 라우팅되지 않는다"뿐이므로 최소 맵을 쓴다 —
/// 매핑이 비어 있으면 `routeAfterAuthentication()`이 마법사로 보내고, 마법사가 HTTP 응답을
/// 하나 더 소비해 `ScriptedHTTP`의 순서가 어긋난다.
private let activeOnlyWorkflow = WorkflowMap(statusToStage: ["In Progress": .active])

/// 로그인하면 필드 목록을 한 번 조회해 스프린트 필드 ID를 저장한다.
@MainActor
@Test func findsAndStoresTheSprintFieldOnSignIn() async throws {
    let sprintField = InMemorySprintFieldStore()
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: activeOnlyWorkflow),
        sprintField: sprintField,
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 200, body: Data(fieldsBody.utf8)),
            ])
        }
    )

    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")

    #expect(try sprintField.load() == "customfield_10020")
}

/// 스프린트를 쓰지 않는 사이트에서도 로그인이 정상으로 끝나야 한다.
/// 필드가 없다는 것은 오류가 아니라 사실이다.
@MainActor
@Test func signsInNormallyWhenTheSiteHasNoSprintField() async throws {
    let sprintField = InMemorySprintFieldStore()
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: activeOnlyWorkflow),
        sprintField: sprintField,
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 200, body: Data("""
                [{"id":"summary","name":"Summary","schema":{"type":"string"}}]
                """.utf8)),
            ])
        }
    )

    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")

    #expect(try sprintField.load() == nil)
    // 로그인이 끝났다는 것은 계정을 알아냈다는 뜻이다. `Phase` 비교보다 이쪽이
    // 연관값에 흔들리지 않는다.
    #expect(model.myAccountId != nil)
}

/// `/field` 조회가 실패해도 로그인을 막지 않는다 — 이월 표시만 없는 채로 돈다.
@MainActor
@Test func survivesAFailedFieldLookup() async throws {
    let sprintField = InMemorySprintFieldStore()
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: activeOnlyWorkflow),
        sprintField: sprintField,
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 500, body: Data()),
            ])
        }
    )

    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")

    #expect(try sprintField.load() == nil)
}

/// 계정이 바뀌면 필드 ID를 버린다 — 다른 테넌트에 그 필드는 없다.
@MainActor
@Test func forgetsTheFieldIDOnSignOut() async throws {
    let sprintField = InMemorySprintFieldStore(seeded: "customfield_10020")
    let model = try makeModel(sprintField: sprintField)

    await model.signOut()

    #expect(try sprintField.load() == nil)
}
```

`TestSupport.swift`의 `makeModel`에 파라미터를 더한다:

```swift
    sprintField: InMemorySprintFieldStore = InMemorySprintFieldStore(),
```

그리고 `AppModel(...)` 생성 인자에 `sprintField: sprintField,`를 더한다.

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter SprintFieldStore
```

기대: 컴파일 실패 — `extra argument 'sprintField' in call`

- [ ] **Step 3: `IssueSource`가 필드 ID를 쓰게 한다**

`SyncEngine.swift`의 `JiraIssueSource`에 저장 프로퍼티를 더한다:

```swift
public struct JiraIssueSource: IssueSource {
    private let client: JiraClient
    /// 스프린트 커스텀 필드 ID. 없으면 스프린트를 요청하지 않는다.
    private let sprintFieldID: String?
    private let baseFields = [
        "summary", "status", "issuetype", "priority", "assignee", "duedate", "updated",
    ]

    public init(client: JiraClient, sprintFieldID: String? = nil) {
        self.client = client
        self.sprintFieldID = sprintFieldID
    }

    public func fetchAssignedIssues(jql: String) async throws -> FetchResult {
        // 필드 ID를 모르면 요청 목록에 넣지 않는다 — 존재하지 않는 필드를 요청하면
        // Jira가 400을 주는 경우가 있어 동기화 전체가 실패할 수 있다.
        let fields = sprintFieldID.map { baseFields + [$0] } ?? baseFields

        var collected: [ObservedIssue] = []
        var failures = 0
        var token: String?

        repeat {
            let page = try await client.searchIssues(
                jql: jql, fields: fields, maxResults: 100, pageToken: token,
                sprintFieldID: sprintFieldID
            )
            collected.append(contentsOf: page.issues.map(ObservedIssue.init))
            failures += page.failures.count
            token = page.nextPageToken
        } while token != nil

        return FetchResult(issues: collected, decodingFailures: failures)
    }
}
```

- [ ] **Step 4: `AppModel`이 필드 ID를 확보하고 넘긴다**

`init`에 저장소를 받는다 (기본값 없이 — `JirarcadeApp.swift`에서 주입한다):

```swift
    private let sprintField: any SprintFieldStore
```

`validate(_:persistOnSuccess:)`에서 `siteHost`를 채우는 자리 바로 아래에 넣는다:

```swift
        // 스프린트 필드 ID를 한 번 찾아 저장한다. 실패해도 로그인을 막지 않는다 —
        // 스프린트를 쓰지 않는 사이트도 있고, 없다는 것은 오류가 아니라 사실이다.
        // 표시가 빠질 뿐 나머지는 그대로 돈다.
        if let data = try? await candidate.fields(),
           let id = try? JiraFieldCatalog.sprintFieldID(in: data) {
            try? sprintField.save(id)
        }
```

`signOut()`에서 `siteHost = nil` 옆에 넣는다:

```swift
        // 다른 테넌트에는 그 필드가 없다. 남겨두면 존재하지 않는 필드를 계속 요청한다.
        try? sprintField.clear()
```

`performSync()`가 `JiraIssueSource`를 만드는 자리에 필드 ID를 넘긴다:

```swift
            source: JiraIssueSource(client: client,
                                    sprintFieldID: try? sprintField.load()),
```

- [ ] **Step 5: 앱 조립부에 저장소를 넣는다**

`Sources/JirarcadeApp/JirarcadeApp.swift`의 `AppModel(...)` 생성에 더한다:

```swift
            sprintField: {
                do { return try FileSprintFieldStore.applicationSupport() }
                catch {
                    // 설정 디렉터리를 못 열면 워크플로 저장소도 이미 실패했을 것이다.
                    // 여기서 앱을 죽이지 않고 메모리 저장소로 degrade한다 — 이월 표시는
                    // 이번 실행에서만 빠지고 다음 실행에서 다시 시도한다.
                    return InMemorySprintFieldStore()
                }
            }(),
```

- [ ] **Step 6: 테스트가 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter SprintFieldStore
```

기대: 8 tests PASS

- [ ] **Step 7: 전체 테스트를 돌린다**

```bash
cd Packages/Jirarcade && swift test
```

기대: 전체 PASS. **`ScriptedHTTP`가 응답을 순서대로 돌려주므로, 로그인 경로에 `/field` 호출이
하나 늘어난 것 때문에 기존 테스트가 깨질 수 있다.** 깨진 테스트는 스크립트에 응답을 하나
더해 고친다 — 호출 순서는 `/myself` → `/field` → (매핑 후보 조회 또는 검색)이다.

- [ ] **Step 8: 채점이 그대로인지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter "ScoreEngine|XpAwarder|Hygiene|AbuseGuard|EndToEnd"
```

기대: 전체 PASS. 이 계획은 표시만 더하므로 **채점 관련 테스트가 하나라도 깨지면 그것이 결함이다.**

- [ ] **Step 9: 커밋**

```bash
git add Packages/Jirarcade/Sources/ Packages/Jirarcade/Tests/
git commit -m "feat: 로그인 시 스프린트 필드를 찾고 동기화가 그 필드를 요청한다

필드 조회 실패가 로그인을 막지 않는다. 스프린트를 쓰지 않는 사이트도 있고
없다는 것은 오류가 아니라 사실이다 — 표시가 빠질 뿐 나머지는 그대로 돈다.

필드 ID를 모르면 검색 요청 목록에 넣지 않는다. 존재하지 않는 필드를 요청하면
Jira가 400을 주는 경우가 있어 동기화 전체가 실패할 수 있다.

계정이 바뀌면 필드 ID를 버린다 — 다른 테넌트에 그 필드는 없다."
```

---

### Task 6: 카드에 이월 줄과 툴팁

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Board/BoardLayout.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/TicketCardView.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/BoardLayoutTests.swift` (덧붙임)

**Interfaces:**
- Consumes: `ObservedIssue.sprintCarryOvers`·`.firstSprintName`·`.latestSprintName` (Task 4)
- Produces: `BoardSlot.sprintCarryOvers: Int`, `.firstSprintName: String?`, `.latestSprintName: String?`

- [ ] **Step 1: 실패하는 테스트를 덧붙인다**

`BoardLayoutTests.swift` 끝에 추가한다:

```swift
/// 보드는 이월 정보를 옮기기만 한다 — 새 판단은 하지 않는다.
@Test func carriesSprintInformationOntoTheSlot() {
    let issue = ObservedIssue(
        key: "DEMO-1", summary: "샘플", statusName: "In Progress", issueType: "개선",
        priority: nil, assigneeAccountId: "acc-me", assigneeName: "tester",
        dueDate: nil, jiraUpdatedAt: now,
        sprintCarryOvers: 12,
        firstSprintName: "DEMO 스프린트 (52)",
        latestSprintName: "DEMO 스프린트 (66)"
    )

    let slot = snapshot([issue]).lanes[1].slots[0]

    #expect(slot.sprintCarryOvers == 12)
    #expect(slot.firstSprintName == "DEMO 스프린트 (52)")
    #expect(slot.latestSprintName == "DEMO 스프린트 (66)")
}

/// 스프린트를 쓰지 않는 티켓은 0이고 이름이 없다.
@Test func reportsNoSprintInformationWhenThereIsNone() {
    let slot = snapshot([issue(key: "DEMO-1", status: "In Progress")]).lanes[1].slots[0]

    #expect(slot.sprintCarryOvers == 0)
    #expect(slot.firstSprintName == nil)
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter BoardLayout
```

기대: 컴파일 실패 — `value of type 'BoardSlot' has no member 'sprintCarryOvers'`

- [ ] **Step 3: `BoardSlot`에 세 값을 더한다**

`BoardLayout.swift`의 `BoardSlot`에 프로퍼티와 init 파라미터를 더한다 (기본값 없이 —
생성 지점이 `snapshot`과 `withRow` 둘뿐이라 전부 고치는 편이 안전하다):

```swift
    /// 스프린트 이월 횟수. **표시 전용이며 채점에 쓰지 않는다.**
    public let sprintCarryOvers: Int
    /// 툴팁이 "A → B" 문장을 만들 때 쓴다. 문장 조립은 뷰의 몫이다.
    public let firstSprintName: String?
    public let latestSprintName: String?
```

`snapshot`의 `BoardSlot(...)` 생성에 넣는다:

```swift
                sprintCarryOvers: issue.sprintCarryOvers,
                firstSprintName: issue.firstSprintName,
                latestSprintName: issue.latestSprintName
```

`LanePacker.swift`의 `withRow`에도 세 값을 그대로 넘긴다 — 빠뜨리면 packing을 거친 슬롯만
이월이 0으로 보인다.

- [ ] **Step 4: 카드에 줄과 툴팁을 더한다**

`TicketCardView.swift`의 `body`에서, 마감일 줄 **다음이자** 대기·실패·메뉴 분기 **앞**에 넣는다:

```swift
            // 이월은 대기·실패 블록이 없을 때만 그린다. 그 둘은 그 순간 행동을 요구하는
            // 정보라 우선하고, 카드 높이 예산이 이미 빠듯하다(실패 상태에서 96pt 중 92pt).
            if slot.sprintCarryOvers > 0, pending == nil, failure == nil {
                Text("↻ 스프린트 \(slot.sprintCarryOvers)회")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.inkTertiary)
                    .help(sprintTooltip)
            }
```

툴팁 문장을 뷰가 조립한다:

```swift
    /// `ArcadeCore`는 이름 둘을 사실로만 담는다. 문장은 여기서 만든다 —
    /// `DueState`·`HygieneNextStep`과 같은 경계다.
    private var sprintTooltip: String {
        guard let first = slot.firstSprintName, let latest = slot.latestSprintName
        else { return "" }
        return first == latest ? first : "\(first) → \(latest)"
    }
```

**색은 `inkTertiary`다.** 이월은 사실이지 경고가 아니다 — 등급 배지가 이미 위험을 말하고
있고, 같은 카드에 두 번째 경고색을 넣으면 어느 쪽을 봐야 할지 흐려진다.

**0회면 줄을 그리지 않는다.** 대부분의 티켓이 0이고 "스프린트 0회"는 아무것도 말하지 않으면서
카드만 어지럽힌다.

- [ ] **Step 5: 카드 높이 예산을 확인한다**

이월 줄이 들어가는 것은 **대기·실패 블록이 없는 상태**뿐이다. 그 상태의 기존 예산은
콘텐츠 박스 96pt(= `cardHeight` 112 − 패딩 16) 중 82pt였다(퀘스트 보드 계획 Task 11).

이월 줄은 9pt 텍스트 한 줄 + `VStack` 간격 3pt = 약 14pt를 더한다 → 96pt.

**딱 맞으므로 반드시 확인할 것.** 실제 폰트 메트릭이 예상과 다르면 `BoardMetrics.cardHeight`를
120으로 올린다. 그 경우 레인 높이가 카드당 8pt 늘어나며, 스크롤뷰 안이라 감당 가능하다.
계산과 결정을 보고서에 적을 것.

- [ ] **Step 6: 테스트가 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test
```

기대: 전체 PASS.

- [ ] **Step 7: 제약을 확인한다**

```bash
rg 'Date\(\)|Calendar\.current|RuleSet\.default' Packages/Jirarcade/Sources/ArcadeUI/ | wc -l
```

기대: `0`

```bash
cd Packages/Jirarcade && swift test --filter viewsUseThemeTokens
```

기대: PASS

- [ ] **Step 8: 눈으로 확인한다**

`ArcadeUI`에는 테스트 타깃이 없다. GUI를 띄울 수 없는 환경이면 **BLOCKED로 처리하지 말고**
빌드와 테스트를 통과시킨 뒤 코드 판독으로 확인하고, 시각 확인을 하지 않았다고 보고할 것.

띄울 수 있다면 — 번들로 실행해야 한다(`swift run`은 접근성 API에 창이 보이지 않는다):

```bash
./scripts/make-app.sh --open
```

확인:
- 여러 스프린트를 거친 티켓의 카드에 `↻ 스프린트 N회`가 뜬다
- 그 줄에 마우스를 올리면 `첫 스프린트 → 마지막 스프린트` 툴팁이 뜬다
- 스프린트가 없거나 하나뿐인 티켓에는 줄이 없다
- 전이를 대기 중이거나 실패한 카드에는 이월 줄 대신 그 정보가 뜬다
- 카드 아래가 잘리지 않는다

- [ ] **Step 9: 커밋**

```bash
git add Packages/Jirarcade/Sources/ Packages/Jirarcade/Tests/
git commit -m "feat: 카드에 스프린트 이월 횟수를 표시한다

0회면 줄을 그리지 않는다 — 대부분의 티켓이 0이고 '스프린트 0회'는 아무것도
말하지 않으면서 카드만 어지럽힌다.

대기·실패 블록이 있으면 이월 줄을 양보한다. 그 둘은 그 순간 행동을 요구하는
정보이고 카드 높이 예산이 빠듯하다.

색은 inkTertiary다. 이월은 사실이지 경고가 아니며, 등급 배지가 이미 위험을
말하고 있는 카드에 두 번째 경고색을 넣으면 어느 쪽을 봐야 할지 흐려진다.

툴팁 문장은 뷰가 조립한다 — ArcadeCore는 이름 둘을 사실로만 담는다."
```

---

### Task 7: 완성 정의 확인과 README 갱신

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 전체 테스트를 돌리고 개수를 기록한다**

```bash
cd Packages/Jirarcade && swift test 2>&1 | tail -3
```

실제 개수를 적어둔다. README가 그 숫자를 두 곳에서 말한다.

- [ ] **Step 2: 채점 불변을 확인한다**

이 계획의 안전장치다. 표시만 더했으므로 **채점 결과가 바뀌면 그것이 결함이다.**

```bash
cd Packages/Jirarcade && swift test --filter "ScoreEngine|XpAwarder|Hygiene|AbuseGuard|Streak|LevelCurve|EndToEnd"
```

기대: 전체 PASS, 실패 0.

- [ ] **Step 3: 완성 정의를 확인한다**

스펙 §10의 항목을 순서대로 확인한다:

```
□ 로그인하면 스프린트 필드 ID를 한 번 조회해 저장한다
□ 필드 이름이 "Sprint"가 아닌 사이트에서도 찾는다
□ 여러 스프린트를 거친 티켓의 카드에 이월 횟수가 뜬다
□ 툴팁에 첫·마지막 스프린트 이름이 시간순으로 뜬다
□ 스프린트가 없거나 하나뿐인 티켓에는 줄이 없다
□ 스프린트를 쓰지 않는 사이트에서도 앱이 정상 동작하고 경고가 없다
□ 기존 미러가 있는 상태에서 앱을 올려도 열린다 (마이그레이션)
□ XP·레벨·위생 값이 이 계획 전후로 동일하다
□ swift test 전부 통과
```

두 번째 항목은 자동 테스트가 고정한다(`findsTheSprintFieldBySchemaNotByName`).
일곱 번째는 이미 동기화된 DB가 있는 상태에서 앱을 띄워 확인한다.

- [ ] **Step 4: README를 갱신한다**

"동작합니다" 목록에 한 줄 더한다:

```markdown
- 카드에 스프린트 이월 횟수 — 티켓이 몇 번이나 다음 스프린트로 미뤄졌는지
```

"아직 없습니다"에서 `- 스프린트 보드 (계획 2b-3)` 줄을 지운다. 그 자리에 남은 범위를 적는다:

```markdown
- 스프린트별 보기·필터 (활성 스프린트를 쓰는 조직이 되면)
```

테스트 개수를 Step 1에서 측정한 값으로 고친다 — README는 그 숫자를 **두 곳**에서 말한다
(`## 테스트` 절과 `## 구조` 절의 모듈 경계 설명).

문서 표에 이 계획의 스펙을 더한다:

```markdown
| [스프린트 이월 설계](docs/superpowers/specs/2026-08-24-sprint-carryover-design.md) | 스프린트 필드 식별·이월 계산·표시 경계 |
```

- [ ] **Step 5: 커밋**

```bash
git add README.md
git commit -m "docs: 스프린트 이월 표시를 동작하는 기능으로 옮긴다"
```

---

## 완성 확인

이 계획이 끝나면 다음이 참이다:

- 스프린트 필드를 로케일과 무관하게 찾고, 없는 사이트에서도 앱이 정상 동작한다
- 여러 스프린트를 거친 티켓의 카드가 그 횟수를 말하고, 툴팁이 어느 스프린트부터였는지 말한다
- **채점 결과가 이 계획 전후로 동일하다** — 이월은 표시 전용이다
- 기존 미러가 있는 사용자가 앱을 올려도 열린다

## 다음 계획

- **2b-2** 티켓 상세 · 제목/본문 수정 · 댓글 — ADF 처리와, 이슈 #6(정체일 리셋)의 결론이 선행 과제다.
  댓글은 Jira의 `updated`를 갱신하므로 정체일 기준선을 민다. 앱 안에 댓글 입력창을 넣으면
  사용자가 앱에서 자기 티켓의 정체일을 리셋할 수 있게 된다.
