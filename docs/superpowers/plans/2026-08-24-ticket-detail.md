# 티켓 상세·제목 수정·댓글 등록 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 카드를 누르면 티켓의 본문과 최근 댓글을 읽고, 제목을 고치고, 댓글을 달 수 있게 한다.

**Architecture:** ADF(Atlassian Document Format) 파싱은 `JiraKit`, 화면에 그릴 문자열로 옮기는 판단은 `ArcadeCore`, 그리기만 `ArcadeUI`가 맡는다. 본문과 댓글은 미러에 넣지 않고 시트가 열려 있는 동안만 화면 상태로 둔다. 쓰기는 앱이 점수를 직접 주지 않고 `syncNow()`로 관측을 유발한다.

**Tech Stack:** Swift 6.2, SwiftUI, SwiftData, Swift Testing (`@Test` / `#expect`)

**Spec:** `docs/superpowers/specs/2026-08-24-ticket-detail-design.md`

## Global Constraints

- 모듈 의존은 단방향이다: `ArcadeUI → ArcadeApp → ArcadeCore → JiraKit`. 역방향 import 금지.
- **`ArcadeApp`은 SwiftUI를 import하지 않는다.** `ModuleBoundaryTests`가 소스 텍스트로 강제한다.
- **`ArcadeUI`에는 테스트 타깃이 없다.** 판단이 뷰에 들어가면 어떤 테스트도 닿지 못한다. 뷰에는 좌표 계산과 문자열 보간만 둔다.
- 조직 특정 정보(실제 사이트 주소·프로젝트 키·커스텀 상태명·실제 커스텀 필드 ID)를 코드·테스트·README에 넣지 않는다. `example.atlassian.net`과 `DEMO-`만 쓴다.
- **Jira 응답 본문 조각이 화면·로그·저장소에 닿지 않는다.** 토큰·이메일도 마찬가지다.
- 테스트는 Swift Testing(`@Test` / `#expect`)을 쓴다. XCTest를 쓰지 않는다.
- **코드 주석에 설계문서 § 참조를 넣지 않는다.** 이유는 문장으로 남기고 인용만 뺀다.
- 각 태스크는 `swift test` 전체 통과 후 커밋으로 끝난다.
- 테스트 실행은 절대 경로로: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`. 현재 538개, 약 6초.
- SourceKit 진단은 모듈 경계를 넘으면 낡은 정보를 보여준다("cannot find type in scope"). `swift test`로 판단한다.

## 파일 구조

**신규**

| 파일 | 책임 |
|---|---|
| `Sources/JiraKit/JiraTimestamp.swift` | ISO8601 파싱. `DTO.swift`의 `fileprivate` 헬퍼를 옮겨 공유한다 |
| `Sources/JiraKit/ADFNode.swift` | ADF JSON → 트리. 파싱만 |
| `Sources/JiraKit/ADFDocument.swift` | 우리가 만들어 보내는 ADF. 인코딩 전용 |
| `Sources/JiraKit/IssueDetailDTO.swift` | 상세 조회·댓글 페이지 응답 |
| `Sources/ArcadeCore/Domain/ADFRenderer.swift` | ADF → 화면에 그릴 평문 |
| `Sources/ArcadeCore/Domain/ADFBuilder.swift` | 입력 문자열 → `ADFDocument` |
| `Sources/ArcadeApp/IssueDetail.swift` | 시트가 들고 있는 값과 편집 상태 |
| `Sources/ArcadeUI/TicketDetail/TicketDetailSheet.swift` | 시트 본체 |
| `Sources/ArcadeUI/TicketDetail/CommentListView.swift` | 댓글 목록 |

**수정**

| 파일 | 무엇을 |
|---|---|
| `Sources/ArcadeCore/Rules/XpAwarder.swift` | `.touched`가 0을 돌려준다 |
| `Sources/JiraKit/DTO.swift` | `parseTimestamp`를 `JiraTimestamp`로 위임 |
| `Sources/JiraKit/JiraClient.swift` | 상세·댓글 조회, 제목 저장, 댓글 등록 |
| `Sources/ArcadeApp/AppModel.swift` | 상세 로딩, 편집 생명주기, `signOut()` 정리 |
| `Sources/ArcadeUI/QuestBoard/TicketCardView.swift` | 카드를 눌러 시트를 연다 |
| `Sources/ArcadeUI/QuestBoard/QuestBoardView.swift` | 시트 표시 |

## 태스크 순서 제약

**Task 1이 반드시 먼저다.** 댓글 등록(Task 9)이 `.touched`의 깨우기 XP가 살아 있는 채로 들어가면, 앱이 스스로 파밍 가능한 이벤트를 찍는다 — 정체된 티켓에 댓글 한 줄로 최대 160 XP다. 순서를 바꾸지 않는다.

---

### Task 1: `.touched`가 XP를 주지 않는다

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Rules/XpAwarder.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/XpAwarderTests.swift`, `Packages/Jirarcade/Tests/ArcadeCoreTests/ScoreEngineTests.swift`

**Interfaces:**
- Consumes: 없음 (첫 태스크)
- Produces: 없음. 나머지 태스크가 의존하는 타입을 만들지 않는다. 이 태스크는 **뒤 태스크가 안전해지는 전제**를 만든다.

**배경으로 알아둘 것:** `wakeXP(event:issue:statusEnteredAt:now:)` 함수 자체는 지운다. `transitionXP`가 내부에서 호출하므로 함수는 남고, `.touched` 분기만 0을 돌려준다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/ArcadeCoreTests/XpAwarderTests.swift` 끝에 더한다.

```swift
/// 댓글 한 줄로 정체를 "깨웠다"고 점수를 주면, 앱 안에 댓글 상자를 두는 순간
/// 한 번 클릭으로 XP를 얻는 버튼이 된다. 정체를 깨우는 신호는 상태 전이뿐이다.
@Test func touchedEarnsNothingNoMatterHowStagnant() {
    let awarder = XpAwarder(rules: .default, workflow: demoWorkflow,
                            myAccountId: "acc-me", calendar: utc)
    let event = DomainEvent(
        issueKey: "DEMO-1", kind: .touched, fromStatus: nil, toStatus: nil,
        observedAt: iso("2026-08-24T09:00:00Z"), actorAccountId: "acc-me",
        priorUpdatedAt: iso("2026-05-01T09:00:00Z"), dueDateAtObservation: nil
    )

    let xp = awarder.baseXP(for: event, issue: nil, statusEnteredAt: nil,
                            now: iso("2026-08-24T09:00:00Z"))

    #expect(xp == 0)
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter touchedEarnsNothingNoMatterHowStagnant`

Expected: FAIL. 115일 정체이므로 `wakeXP`가 배수 상한까지 올라간 값을 돌려준다.

**확인된 것:** 채점 메서드는 `baseXP(for:issue:statusEnteredAt:now:)`다(`xp(for:)`가 아니다). `XpAwarder.init`은 `(rules:workflow:myAccountId:calendar:)`, `ScoreEngine.init`은 `(rules:workflow:calendar:myAccountId:)`로 **인자 순서가 다르다**. 픽스처 `utc`·`demoWorkflow`·`iso(_:)`·`issue(key:status:)`는 `Tests/ArcadeCoreTests/`에 이미 있다 — 새로 만들지 않는다.

- [ ] **Step 3: 구현한다**

`XpAwarder.swift`의 `switch event.kind` 블록에서 `.touched` 분기를 바꾼다.

```swift
        switch event.kind {
        case .appeared, .vanished, .dueDateChanged:
            return 0
        case .touched:
            // "무엇이든 갱신됐다"는 정체를 깬 증거가 아니다. 댓글·워크로그·필드 수정이
            // 전부 여기로 들어오고, 그중 어느 것도 티켓을 앞으로 옮기지 않는다.
            // 앱이 댓글을 쓸 수 있게 된 뒤로는 이 분기가 자기 점수를 벌어들이는
            // 경로가 된다 — 실제 작업 없이 반복할 수 있기 때문이다.
            return 0
        case .statusChanged:
            return transitionXP(event: event, issue: issue, statusEnteredAt: statusEnteredAt, now: now)
        }
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter touchedEarnsNothingNoMatterHowStagnant`

Expected: PASS

- [ ] **Step 5: 연속 기록 회귀 테스트를 더한다**

`ScoreEngine.checkInDays`는 **XP가 붙은 이벤트가 하루에 한 건이라도 있으면 그날을 체크인으로 센다.** 그날의 유일한 XP가 touched였다면 그날이 체크인에서 빠지고, 연속 기록이 끊기면 이후 모든 날의 배수가 달라진다. 이 태스크가 그 성질을 바꾸므로 고정한다.

`Tests/ArcadeCoreTests/ScoreEngineTests.swift` 끝에 더한다.

```swift
/// touched만 있는 날은 체크인이 아니다. 체크인은 XP가 붙은 날의 집합이고,
/// touched가 0점이 된 뒤로는 그런 날이 점수에도 연속 기록에도 남지 않는다.
@Test func aDayWithOnlyTouchedEventsIsNotACheckIn() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow,
                             calendar: utc, myAccountId: "acc-me")
    let events = [
        DomainEvent(issueKey: "DEMO-1", kind: .touched, fromStatus: nil, toStatus: nil,
                    observedAt: iso("2026-08-20T09:00:00Z"), actorAccountId: "acc-me",
                    priorUpdatedAt: iso("2026-05-01T09:00:00Z"), dueDateAtObservation: nil)
    ]

    let (_, summary) = engine.recompute(events: events, issues: [],
                                        now: iso("2026-08-24T09:00:00Z"))

    #expect(summary.totalXP == 0)
    #expect(summary.streak.currentStreak == 0)
}
```

**확인된 것:** `PlayerSummary`는 `ScoreEngine.swift`에 있고 `totalXP: Int`와 `streak: StreakState`를 갖는다. `StreakState`의 필드는 `currentStreak`이다.

- [ ] **Step 6: 전체 테스트를 돌린다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`

Expected: 전부 통과. **기존 테스트가 깨지면 그것이 이 변경의 실제 파급이다** — 깨진 테스트가 touched에 점수를 기대하고 있었다면 그 기대를 0으로 고친다. 다른 이유로 깨졌다면 멈추고 보고한다.

- [ ] **Step 7: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Rules/XpAwarder.swift Packages/Jirarcade/Tests/ArcadeCoreTests/
git commit -m "fix: 단순 갱신은 정체를 깬 증거가 아니므로 XP를 주지 않는다"
```

---

### Task 2: ISO8601 파서 추출과 ADF 파싱

**Files:**
- Create: `Packages/Jirarcade/Sources/JiraKit/JiraTimestamp.swift`
- Create: `Packages/Jirarcade/Sources/JiraKit/ADFNode.swift`
- Modify: `Packages/Jirarcade/Sources/JiraKit/DTO.swift:118-145`
- Test: `Packages/Jirarcade/Tests/JiraKitTests/ADFNodeTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `JiraTimestamp.parse(_ text: String) -> Date?`
  - `ADFNode` — `type: String`, `text: String?`, `attrs: [String: String]`, `content: [ADFNode]`, `hasMarks: Bool`
  - `ADFNode.decode(_ data: Data) throws -> ADFNode`
  - `public init(type:text:attrs:content:hasMarks:)` (테스트가 트리를 손으로 만든다)

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/JiraKitTests/ADFNodeTests.swift`를 만든다.

```swift
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
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter ADFNodeTests`

Expected: FAIL — `ADFNode`가 없어 컴파일되지 않는다.

- [ ] **Step 3: `JiraTimestamp`를 만든다**

`Sources/JiraKit/JiraTimestamp.swift`:

```swift
import Foundation

/// Jira가 주는 타임스탬프 문자열을 `Date`로 옮긴다.
///
/// `DTO.swift`가 `fileprivate`로 갖고 있던 것을 옮겼다. 상세·댓글 응답도 같은 형식을
/// 쓰는데 다른 파일에서는 닿지 않아, 파서가 둘로 갈라질 자리였다.
public enum JiraTimestamp {
    // ISO8601DateFormatter는 Sendable을 준수하지 않지만, 설정을 마친 뒤 값을 바꾸지 않고
    // 파싱에만 쓰므로 안전하다(Apple 문서상 이 포매터는 스레드 세이프).
    //
    // `.withFractionalSeconds`가 켜진 포매터는 소수점이 **없으면 nil을 돌려준다**.
    // Jira Cloud는 보통 `.000`을 붙이지만 배포·프록시에 따라 빠질 수 있고, 그때 값이
    // 통째로 파싱 실패한다. 두 포매터를 순서대로 시도한다.
    nonisolated(unsafe) private static let formatters: [ISO8601DateFormatter] = {
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

    public static func parse(_ text: String) -> Date? {
        for formatter in formatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
```

- [ ] **Step 4: `DTO.swift`가 새 파서에 위임하게 한다**

`DTO.swift`의 `timestampFormatters` 상수와 `parseTimestamp` 본문을 지우고, 호출자가 그대로 쓰도록 한 줄로 남긴다.

```swift
extension JiraSearchResponse {
    fileprivate static func parseTimestamp(_ text: String) -> Date? {
        JiraTimestamp.parse(text)
    }
}
```

**주의:** `parseTimestamp`의 호출자를 `rg "parseTimestamp" Sources/JiraKit/`로 전부 찾아 시그니처가 그대로인지 확인한다. 이 단계는 동작을 바꾸지 않는 순수 이동이므로, 기존 테스트 538개가 그대로 통과해야 한다. 하나라도 깨지면 이동이 잘못된 것이다.

- [ ] **Step 5: `ADFNode`를 만든다**

`Sources/JiraKit/ADFNode.swift`:

```swift
import Foundation

/// ADF(Atlassian Document Format) 트리의 노드 하나.
///
/// **파싱만 한다.** 무엇을 화면에 어떻게 그릴지는 `ArcadeCore`가 정한다 — 이 타입은
/// 응답에 무엇이 들어 있었는지만 말한다.
///
/// `attrs`에서 문자열 값만 남기는 이유: ADF의 attrs는 종류마다 타입이 제각각이고
/// (`width`는 숫자, `layout`은 문자열) 새 속성이 예고 없이 추가된다. 화면에 필요한
/// 값(`text`·`shortName`·`url`)은 전부 문자열이므로, 나머지를 버리는 편이
/// 하나라도 못 읽으면 문단 전체를 잃는 것보다 낫다.
public struct ADFNode: Sendable, Equatable {
    public let type: String
    public let text: String?
    public let attrs: [String: String]
    public let content: [ADFNode]
    /// 굵게·기울임·링크 같은 서식이 붙어 있는지. 값은 담지 않는다 — 평문으로 그리는
    /// 동안에는 쓰지 않고, 본문 편집을 여는 단계가 "손실 없이 왕복 가능한가"를
    /// 판단할 때만 필요하다.
    public let hasMarks: Bool

    public init(type: String, text: String? = nil, attrs: [String: String] = [:],
                content: [ADFNode] = [], hasMarks: Bool = false) {
        self.type = type
        self.text = text
        self.attrs = attrs
        self.content = content
        self.hasMarks = hasMarks
    }

    public static func decode(_ data: Data) throws -> ADFNode {
        try JSONDecoder().decode(ADFNode.self, from: data)
    }
}

extension ADFNode: Decodable {
    private enum CodingKeys: String, CodingKey { case type, text, attrs, content, marks }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        content = (try? container.decode([ADFNode].self, forKey: .content)) ?? []
        hasMarks = container.contains(.marks)
        attrs = (try? container.decode(StringAttributes.self, forKey: .attrs))?.values ?? [:]
    }
}

/// 어떤 키가 올지 모르는 객체에서 **문자열 값만** 건져낸다.
private struct StringAttributes: Decodable {
    let values: [String: String]

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var found: [String: String] = [:]
        for key in container.allKeys {
            if let value = try? container.decode(String.self, forKey: key) {
                found[key.stringValue] = value
            }
        }
        values = found
    }
}
```

- [ ] **Step 6: 테스트가 통과하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`

Expected: 전부 통과 (538 + 3).

- [ ] **Step 7: 커밋**

```bash
git add Packages/Jirarcade/Sources/JiraKit/ Packages/Jirarcade/Tests/JiraKitTests/ADFNodeTests.swift
git commit -m "feat: ADF 트리를 읽고 타임스탬프 파서를 공유한다"
```

---

### Task 3: 입력 문자열을 ADF로 만든다

**Files:**
- Create: `Packages/Jirarcade/Sources/JiraKit/ADFDocument.swift`
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Domain/ADFBuilder.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/ADFBuilderTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `ADFDocument` (JiraKit) — `Encodable`, `Sendable`, `Equatable`. `ADFDocument.Block`, `ADFDocument.Inline` 중첩 타입
  - `ADFBuilder.paragraphs(from text: String) -> ADFDocument?` (ArcadeCore) — 비어 있으면 `nil`

**왜 두 모듈로 갈리나:** `JiraClient`가 요청 본문으로 인코딩하려면 타입이 `JiraKit`에 있어야 한다(`ArcadeCore`를 import할 수 없다). 문자열을 문단으로 가르는 **규칙**은 판단이므로 `ArcadeCore`에 둔다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/ArcadeCoreTests/ADFBuilderTests.swift`를 만든다.

```swift
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
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter ADFBuilderTests`

Expected: FAIL — 타입이 없어 컴파일되지 않는다.

- [ ] **Step 3: `ADFDocument`를 만든다**

`Sources/JiraKit/ADFDocument.swift`:

```swift
import Foundation

/// 우리가 만들어 Jira로 보내는 ADF 문서.
///
/// 읽기용 `ADFNode`와 나눈 이유: 보내는 문서는 우리가 처음부터 짓기 때문에 모양이
/// 좁고 확정적이다. 읽기 타입을 그대로 쓰면 보낼 수 없는 조합(표·첨부)까지
/// 표현할 수 있게 되어, 만들 수 없는 것을 만들지 않는다는 보장이 사라진다.
public struct ADFDocument: Encodable, Sendable, Equatable {
    public let version: Int
    public let type: String
    public let content: [Block]

    public init(content: [Block]) {
        self.version = 1
        self.type = "doc"
        self.content = content
    }

    public struct Block: Encodable, Sendable, Equatable {
        public let type: String
        public let content: [Inline]

        public init(content: [Inline]) {
            self.type = "paragraph"
            self.content = content
        }
    }

    public struct Inline: Encodable, Sendable, Equatable {
        /// `"text"` 또는 `"hardBreak"`.
        public let type: String
        /// `hardBreak`에는 없다.
        public let text: String?

        public init(type: String, text: String?) {
            self.type = type
            self.text = text
        }
    }
}
```

- [ ] **Step 4: `ADFBuilder`를 만든다**

`Sources/ArcadeCore/Domain/ADFBuilder.swift`:

```swift
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
```

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`

Expected: 전부 통과.

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/JiraKit/ADFDocument.swift Packages/Jirarcade/Sources/ArcadeCore/Domain/ADFBuilder.swift Packages/Jirarcade/Tests/ArcadeCoreTests/ADFBuilderTests.swift
git commit -m "feat: 입력 문자열을 ADF 문단으로 만든다"
```

---

### Task 4: ADF를 화면에 그릴 평문으로 옮긴다

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Domain/ADFRenderer.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/ADFRendererTests.swift`

**Interfaces:**
- Consumes: `ADFNode` (Task 2)
- Produces:
  - `ADFRenderer.plainText(from doc: ADFNode) -> String`
  - `ADFRenderer.attachmentPlaceholder`, `.tablePlaceholder`, `.unsupportedPlaceholder` — 테스트와 뷰가 같은 문자열을 쓴다

**이 태스크가 이 계획에서 가장 중요하다.** 실제 Jira 본문과 댓글에는 문단만 있지 않다. 모르는 노드를 조용히 빠뜨리면 본문 일부가 없는 채로 보이고 사용자는 그게 전부인 줄 안다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/ArcadeCoreTests/ADFRendererTests.swift`를 만든다.

```swift
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
/// 추가하고, 모르는 것을 빠뜨리면 사용자는 본문이 짧아진 것을 알아채지 못한다.
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
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter ADFRendererTests`

Expected: FAIL — `ADFRenderer`가 없다.

- [ ] **Step 3: 구현한다**

`Sources/ArcadeCore/Domain/ADFRenderer.swift`:

```swift
import Foundation
import JiraKit

/// ADF 트리를 화면에 그릴 평문으로 옮긴다.
///
/// **모르는 노드를 빠뜨리지 않는다.** 빠뜨리면 본문 일부가 없는 채로 보이고 사용자는
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
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`

Expected: 전부 통과.

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Domain/ADFRenderer.swift Packages/Jirarcade/Tests/ArcadeCoreTests/ADFRendererTests.swift
git commit -m "feat: ADF를 평문으로 그리고 모르는 노드에 자리표시자를 남긴다"
```

---

### Task 5: 상세·댓글 응답을 읽는다

**Files:**
- Create: `Packages/Jirarcade/Sources/JiraKit/IssueDetailDTO.swift`
- Test: `Packages/Jirarcade/Tests/JiraKitTests/IssueDetailDTOTests.swift`

**Interfaces:**
- Consumes: `ADFNode` (Task 2), `JiraTimestamp` (Task 2)
- Produces:
  - `JiraIssueDetail` — `key: String`, `summary: String`, `description: ADFNode?`
  - `JiraIssueDetail.decode(_ data: Data) throws -> JiraIssueDetail`
  - `JiraComment` — `id: String`, `authorName: String`, `created: Date`, `body: ADFNode?`
  - `JiraComment.decodePage(_ data: Data) throws -> [JiraComment]`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/JiraKitTests/IssueDetailDTOTests.swift`를 만든다.

```swift
import Testing
import Foundation
@testable import JiraKit

@Test func readsKeySummaryAndDescription() throws {
    let json = #"""
    {"key":"DEMO-1","fields":{"summary":"제목","description":{"type":"doc","content":[
      {"type":"paragraph","content":[{"type":"text","text":"본문"}]}
    ]}}}
    """#

    let detail = try JiraIssueDetail.decode(Data(json.utf8))

    #expect(detail.key == "DEMO-1")
    #expect(detail.summary == "제목")
    #expect(detail.description?.content.count == 1)
}

/// 본문이 비어 있는 티켓은 흔하다. description이 null이라고 상세가 통째로
/// 실패하면 제목도 댓글도 못 본다.
@Test func aNullDescriptionIsNotAFailure() throws {
    let json = #"{"key":"DEMO-2","fields":{"summary":"제목만","description":null}}"#

    let detail = try JiraIssueDetail.decode(Data(json.utf8))

    #expect(detail.summary == "제목만")
    #expect(detail.description == nil)
}

@Test func readsCommentsWithAuthorAndTime() throws {
    let json = #"""
    {"comments":[
      {"id":"10","author":{"displayName":"어떤 사람"},"created":"2026-08-24T09:00:00.000+0900",
       "body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"댓글"}]}]}}
    ]}
    """#

    let comments = try JiraComment.decodePage(Data(json.utf8))

    #expect(comments.count == 1)
    #expect(comments[0].id == "10")
    #expect(comments[0].authorName == "어떤 사람")
    #expect(comments[0].body?.content.count == 1)
}

/// 댓글 하나가 이상해도 나머지는 보여야 한다. 한 건 때문에 대화 전체가
/// 사라지면 "지금 무슨 상황인가"를 판단할 수 없다.
@Test func oneBrokenCommentDoesNotDropThePage() throws {
    let json = #"""
    {"comments":[
      {"id":"10","author":{"displayName":"정상"},"created":"2026-08-24T09:00:00.000+0900","body":null},
      {"author":{"displayName":"id 없음"},"created":"2026-08-24T09:05:00.000+0900","body":null}
    ]}
    """#

    let comments = try JiraComment.decodePage(Data(json.utf8))

    #expect(comments.count == 1)
    #expect(comments[0].authorName == "정상")
}

/// 작성자 이름이 빠지는 경우가 있다(삭제된 계정, 앱 사용자). 이름이 없다고
/// 댓글을 버리지 않는다.
@Test func aMissingAuthorNameFallsBack() throws {
    let json = #"""
    {"comments":[
      {"id":"11","created":"2026-08-24T09:00:00.000+0900","body":null}
    ]}
    """#

    let comments = try JiraComment.decodePage(Data(json.utf8))

    #expect(comments.count == 1)
    #expect(comments[0].authorName == "알 수 없음")
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter IssueDetailDTOTests`

Expected: FAIL — 타입이 없다.

- [ ] **Step 3: 구현한다**

`Sources/JiraKit/IssueDetailDTO.swift`:

```swift
import Foundation

/// 시트가 여는 티켓 하나. **미러에 들어가지 않는다** — 채점 입력이 아니고
/// 시트가 닫히면 버린다.
public struct JiraIssueDetail: Sendable, Equatable {
    public let key: String
    public let summary: String
    public let description: ADFNode?

    public init(key: String, summary: String, description: ADFNode?) {
        self.key = key
        self.summary = summary
        self.description = description
    }

    public static func decode(_ data: Data) throws -> JiraIssueDetail {
        let raw: Payload
        do {
            raw = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw JiraError.decoding(context: "issueDetail: \(error)")
        }
        return JiraIssueDetail(key: raw.key, summary: raw.fields.summary,
                               description: raw.fields.description)
    }

    private struct Payload: Decodable {
        let key: String
        let fields: Fields
        struct Fields: Decodable {
            let summary: String
            let description: ADFNode?
        }
    }
}

/// 댓글 한 건.
public struct JiraComment: Sendable, Equatable, Identifiable {
    public let id: String
    public let authorName: String
    public let created: Date
    public let body: ADFNode?

    public init(id: String, authorName: String, created: Date, body: ADFNode?) {
        self.id = id
        self.authorName = authorName
        self.created = created
        self.body = body
    }

    /// 이름을 못 읽었을 때 쓸 자리. 댓글을 버리는 것보다 낫다 — 삭제된 계정이나
    /// 앱이 만든 댓글에서 실제로 빠진다.
    public static let unknownAuthor = "알 수 없음"

    /// 한 건이 깨져도 나머지를 살린다. 대화 전체가 사라지면 "지금 무슨 상황인가"를
    /// 판단할 수 없고, 그것이 시트를 여는 이유다.
    public static func decodePage(_ data: Data) throws -> [JiraComment] {
        let page: Page
        do {
            page = try JSONDecoder().decode(Page.self, from: data)
        } catch {
            throw JiraError.decoding(context: "comments: \(error)")
        }
        return page.comments.compactMap { entry in
            guard let id = entry.id, let raw = entry.created,
                  let created = JiraTimestamp.parse(raw) else { return nil }
            return JiraComment(id: id,
                               authorName: entry.author?.displayName ?? unknownAuthor,
                               created: created,
                               body: entry.body)
        }
    }

    private struct Page: Decodable {
        let comments: [Entry]
        struct Entry: Decodable {
            let id: String?
            let created: String?
            let author: Author?
            let body: ADFNode?
            struct Author: Decodable { let displayName: String? }
        }
    }
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`

Expected: 전부 통과.

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/JiraKit/IssueDetailDTO.swift Packages/Jirarcade/Tests/JiraKitTests/IssueDetailDTOTests.swift
git commit -m "feat: 티켓 상세와 댓글 페이지를 읽는다"
```

---

### Task 6: 조회·쓰기 엔드포인트

**Files:**
- Modify: `Packages/Jirarcade/Sources/JiraKit/JiraClient.swift` (`performTransition` 아래)
- Test: `Packages/Jirarcade/Tests/JiraKitTests/JiraClientTests.swift`

**Interfaces:**
- Consumes: `JiraIssueDetail`, `JiraComment` (Task 5), `ADFDocument` (Task 3)
- Produces:
  - `JiraClient.issueDetail(issueKey: String) async throws -> JiraIssueDetail`
  - `JiraClient.comments(issueKey: String, limit: Int) async throws -> [JiraComment]`
  - `JiraClient.updateSummary(issueKey: String, summary: String) async throws`
  - `JiraClient.addComment(issueKey: String, body: ADFDocument) async throws`

**주의:** `perform(method:path:body:resource:query:)`가 이미 존재하고 `query` 기본값이 `[]`다. 새 메서드를 만들지 말고 이것을 쓴다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/JiraKitTests/JiraClientTests.swift`에 더한다.

**있는 것을 쓴다.** `Tests/JiraKitTests/StubHTTPClient.swift`에 `StubHTTPClient`가 이미 있고 `sentRequests: [URLRequest]`로 보낸 요청을 기록한다. `Tests/JiraKitTests/TestSupport.swift`의 `fixtureAuth()`가 `APITokenAuth`를 만든다. 조립은 `JiraClient(auth: fixtureAuth(), http: stub)` 형태이며 `ChangelogEndpointTests.swift`가 그대로 쓴다. **새 HTTP 더블을 만들지 않는다.**

```swift
/// 댓글은 기본이 오래된 순이다. 명시하지 않으면 20건을 받아도 가장 오래된
/// 20건이 오고, 지금 무슨 일이 벌어지는지는 알 수 없다.
@Test func commentsAreRequestedNewestFirst() async throws {
    let stub = StubHTTPClient(status: 200, body: #"{"comments":[]}"#)
    let client = JiraClient(auth: fixtureAuth(), http: stub)

    _ = try await client.comments(issueKey: "DEMO-1", limit: 20)

    let url = try #require(stub.sentRequests.last?.url?.absoluteString)
    #expect(url.contains("orderBy=-created"))
    #expect(url.contains("maxResults=20"))
}

@Test func updatingSummarySendsPutWithFieldsBody() async throws {
    let stub = StubHTTPClient(status: 204, body: "")
    let client = JiraClient(auth: fixtureAuth(), http: stub)

    try await client.updateSummary(issueKey: "DEMO-1", summary: "새 제목")

    let request = try #require(stub.sentRequests.last)
    #expect(request.httpMethod == "PUT")
    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let fields = try #require(json["fields"] as? [String: Any])
    #expect(fields["summary"] as? String == "새 제목")
}

@Test func addingCommentSendsPostWithADFBody() async throws {
    let stub = StubHTTPClient(status: 201, body: "{}")
    let client = JiraClient(auth: fixtureAuth(), http: stub)
    let document = ADFDocument(content: [.init(content: [.init(type: "text", text: "댓글")])])

    try await client.addComment(issueKey: "DEMO-1", body: document)

    let request = try #require(stub.sentRequests.last)
    #expect(request.httpMethod == "POST")
    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let adf = try #require(json["body"] as? [String: Any])
    #expect(adf["type"] as? String == "doc")
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter JiraClientTests`

Expected: FAIL — 메서드가 없다.

- [ ] **Step 3: 구현한다**

`JiraClient.swift`의 `performTransition` 바로 아래에 더한다.

```swift
    // MARK: - 티켓 상세

    public func issueDetail(issueKey: String) async throws -> JiraIssueDetail {
        let data = try await perform(
            method: "GET", path: "/issue/\(issueKey)", body: nil, resource: issueKey,
            query: [URLQueryItem(name: "fields", value: "summary,description")]
        )
        return try JiraIssueDetail.decode(data)
    }

    /// `orderBy`를 명시하는 이유: 기본이 오래된 순이라 20건을 받으면 가장 오래된
    /// 20건이 온다. 시트가 답하려는 질문은 "지금 무슨 상황인가"이므로 최신이 먼저다.
    public func comments(issueKey: String, limit: Int) async throws -> [JiraComment] {
        let data = try await perform(
            method: "GET", path: "/issue/\(issueKey)/comment", body: nil, resource: issueKey,
            query: [URLQueryItem(name: "orderBy", value: "-created"),
                    URLQueryItem(name: "maxResults", value: String(limit))]
        )
        return try JiraComment.decodePage(data)
    }

    public func updateSummary(issueKey: String, summary: String) async throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["fields": ["summary": summary]]
        )
        _ = try await perform(method: "PUT", path: "/issue/\(issueKey)",
                              body: body, resource: issueKey)
    }

    public func addComment(issueKey: String, body document: ADFDocument) async throws {
        let payload = try JSONEncoder().encode(CommentPayload(body: document))
        _ = try await perform(method: "POST", path: "/issue/\(issueKey)/comment",
                              body: payload, resource: issueKey)
    }

    private struct CommentPayload: Encodable {
        let body: ADFDocument
    }
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`

Expected: 전부 통과.

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/JiraKit/JiraClient.swift Packages/Jirarcade/Tests/JiraKitTests/JiraClientTests.swift
git commit -m "feat: 상세·댓글 조회와 제목·댓글 쓰기 엔드포인트"
```

---

### Task 7: 시트가 상세를 받아온다

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeApp/IssueDetail.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/IssueDetailTests.swift`

**Interfaces:**
- Consumes: `JiraClient.issueDetail`, `JiraClient.comments` (Task 6), `ADFRenderer.plainText` (Task 4)
- Produces:
  - `IssueDetailState` — `.idle`, `.loading`, `.loaded(IssueDetailView)`, `.failed(String)`
  - `IssueDetailView` — `key: String`, `summary: String`, `descriptionText: String`, `comments: [CommentView]`
  - `CommentView` — `id: String`, `authorName: String`, `created: Date`, `text: String`
  - `AppModel.detailState: IssueDetailState`
  - `AppModel.openDetail(issueKey: String) async`
  - `AppModel.closeDetail()`
  - `AppModel.commentPageSize` (= 20)

**중요:** 시트 조회는 `performSync`의 실패 축약 밖에서 돈다. **`redactedErrorDescription(_:)`을 직접 거쳐야 한다** — 안 그러면 Jira 응답 본문이 화면에 닿는다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/ArcadeAppTests/IssueDetailTests.swift`를 만든다.

```swift
import Testing
import Foundation
@testable import ArcadeApp
@testable import ArcadeCore
import JiraKit

@MainActor
@Test func openingDetailLoadsSummaryDescriptionAndComments() async throws {
    let detailBody = #"""
    {"key":"DEMO-1","fields":{"summary":"제목","description":{"type":"doc","content":[
      {"type":"paragraph","content":[{"type":"text","text":"본문"}]}]}}}
    """#
    let commentBody = #"""
    {"comments":[{"id":"10","author":{"displayName":"어떤 사람"},
      "created":"2026-08-24T09:00:00.000+0900",
      "body":{"type":"doc","content":[{"type":"paragraph","content":[
        {"type":"text","text":"댓글"}]}]}}]}
    """#
    let model = try makeModel(http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data(detailBody.utf8)),
            .init(status: 200, body: Data(commentBody.utf8)),
        ])
    })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")

    await model.openDetail(issueKey: "DEMO-1")

    guard case .loaded(let detail) = model.detailState else {
        Issue.record("상세가 로드되지 않았다: \(model.detailState)")
        return
    }
    #expect(detail.summary == "제목")
    #expect(detail.descriptionText == "본문")
    #expect(detail.comments.count == 1)
    #expect(detail.comments[0].text == "댓글")
}

/// Jira가 준 사유를 화면에 옮기지 않는다. 시트 조회는 동기화의 축약 경로 밖에서
/// 돌기 때문에 이 처리를 공짜로 얻지 못한다.
@MainActor
@Test func aFailedDetailFetchDoesNotQuoteJira() async throws {
    let rejected = #"{"errorMessages":["someone@example.com 계정에 권한이 없습니다"]}"#
    let model = try makeModel(http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 400, body: Data(rejected.utf8)),
        ])
    })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")

    await model.openDetail(issueKey: "DEMO-1")

    guard case .failed(let message) = model.detailState else {
        Issue.record("실패 상태가 아니다: \(model.detailState)")
        return
    }
    #expect(!message.contains("someone@example.com"))
    #expect(!message.contains("권한이 없습니다"))
}

/// 시트를 닫으면 받아온 것을 버린다. 남겨두면 다음에 다른 티켓을 열 때
/// 이전 티켓의 본문이 잠깐 보인다.
@MainActor
@Test func closingDetailForgetsWhatWasLoaded() async throws {
    let detailBody = #"{"key":"DEMO-1","fields":{"summary":"제목","description":null}}"#
    let model = try makeModel(http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 200, body: Data(detailBody.utf8)),
            .init(status: 200, body: Data(#"{"comments":[]}"#.utf8)),
        ])
    })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    await model.openDetail(issueKey: "DEMO-1")
    guard case .loaded = model.detailState else {
        Issue.record("먼저 로드되어야 한다: \(model.detailState)")
        return
    }

    model.closeDetail()

    #expect(model.detailState == .idle)
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter IssueDetailTests`

Expected: FAIL — 타입과 메서드가 없다.

**주의:** `makeModel`의 기본 `http`는 `/myself` 응답 하나만 큐에 넣는다. 로그인 경로는 `/myself` → `/field` → 매핑 후보/검색 순으로 호출한다. 위 테스트가 로그인 후 응답 순서에서 어긋나면 **스크립트에 응답을 더해 고친다** — 단언을 고치지 않는다. 실제 호출 순서는 `rg "await candidate" Sources/ArcadeApp/AppModel.swift`로 확인한다.

- [ ] **Step 3: 값 타입을 만든다**

`Sources/ArcadeApp/IssueDetail.swift`:

```swift
import Foundation

/// 시트가 그릴 티켓 하나. **미러에 들어가지 않는다** — 채점 입력이 아니고,
/// 넣으면 마이그레이션과 용량이 따라오며 `DiffEngine`이 본문 변화를 이벤트로
/// 오해할 수 있다.
public struct IssueDetailView: Sendable, Equatable {
    public let key: String
    public let summary: String
    /// ADF를 평문으로 옮긴 결과. 모르는 서식은 자리표시자로 남아 있다.
    public let descriptionText: String
    public let comments: [CommentView]
}

public struct CommentView: Sendable, Equatable, Identifiable {
    public let id: String
    public let authorName: String
    public let created: Date
    public let text: String
}

public enum IssueDetailState: Sendable, Equatable {
    case idle
    case loading(issueKey: String)
    case loaded(IssueDetailView)
    /// 화면에 그대로 그릴 문구. **Jira가 준 사유가 들어 있지 않다.**
    case failed(String)
}
```

- [ ] **Step 4: `AppModel`에 로딩을 더한다**

`AppModel`의 관측 프로퍼티 근처(`transitionFailures` 선언 부근)에 상태를 더한다.

```swift
    public private(set) var detailState: IssueDetailState = .idle
```

그리고 `executeTransition` 아래에 메서드를 더한다.

```swift
    /// 시트에 그릴 만큼만 받아온다. 더 필요하면 Jira로 보낸다 — 이 앱은 티켓을
    /// 읽는 도구가 아니라 정체를 재는 도구다.
    public static let commentPageSize = 20

    public func openDetail(issueKey: String) async {
        guard let client else { return }
        detailState = .loading(issueKey: issueKey)
        let generation = syncGeneration

        do {
            let detail = try await client.issueDetail(issueKey: issueKey)
            let comments = try await client.comments(issueKey: issueKey,
                                                     limit: Self.commentPageSize)
            // 받아오는 동안 계정이 바뀌었으면 이 결과는 남의 것이다.
            guard generation == syncGeneration else { return }
            detailState = .loaded(IssueDetailView(
                key: detail.key,
                summary: detail.summary,
                descriptionText: detail.description.map(ADFRenderer.plainText(from:)) ?? "",
                comments: comments.map {
                    CommentView(id: $0.id, authorName: $0.authorName, created: $0.created,
                                text: $0.body.map(ADFRenderer.plainText(from:)) ?? "")
                }
            ))
        } catch JiraError.unauthorized {
            guard generation == syncGeneration else { return }
            phase = .expired
            detailState = .idle
        } catch {
            guard generation == syncGeneration else { return }
            // 동기화 경로의 축약을 여기서는 직접 불러야 한다 — 시트 조회는
            // performSync 밖에서 돌아 그 처리를 물려받지 못한다.
            detailState = .failed(redactedErrorDescription(error))
        }
    }

    public func closeDetail() {
        detailState = .idle
    }
```

**주의:** `redactedErrorDescription(_:)`이 파일 스코프 함수인지 타입 메서드인지 확인하고 호출 형태를 맞춘다 — `rg "func redactedErrorDescription" Sources/ArcadeApp/`.

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`

Expected: 전부 통과.

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeApp/ Packages/Jirarcade/Tests/ArcadeAppTests/IssueDetailTests.swift
git commit -m "feat: 시트가 티켓 상세와 최근 댓글을 받아온다"
```

---

### Task 8: 편집 생명주기와 제목 저장

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/IssueEditTests.swift`

**Interfaces:**
- Consumes: `JiraClient.updateSummary` (Task 6), `IssueDetailState` (Task 7)
- Produces:
  - `AppModel.editInFlight: Set<String>` (읽기 전용 공개)
  - `AppModel.editFailures: [String: String]`
  - `AppModel.saveSummary(issueKey: String, summary: String) async`
  - `AppModel.dismissEditFailure(issueKey: String)`
  - `AppModel.editTaskCountForTesting: Int`

**반드시 미러를 채우고 시작한다.** `saveSummary`와 `postComment`는 `issues.contains(where:)`로 시작한다 — 미러에 없는 티켓은 화면에도 없기 때문이다. 테스트가 `model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])`를 부르지 않으면 그 guard에서 조용히 빠져나가고, 테스트는 **틀린 이유로 통과한다**. `seedIssuesForTesting`과 `issue(key:status:)`는 이미 있다(`TransitionTests.swift`가 같은 방식을 쓴다).

**이 태스크가 이 계획에서 가장 위험하다.** 취소 창을 두지 않기로 했지만, **취소 창을 빼는 것과 대기 상태를 안 만드는 것은 다르다.** `AppModel`의 전이 상태는 취소 버튼만을 위한 것이 아니라 진행 중인 비동기 작업의 수명을 계정 경계에 묶는 장치다. 저장은 `await`이고 그 사이에 계정이 바뀔 수 있다.

지난 사이클에 로그아웃 후 대기 중이던 전이가 **다음 계정의 사이트로** 발사된 적이 있다. 같은 모양을 만들지 않는다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/ArcadeAppTests/IssueEditTests.swift`를 만든다.

```swift
import Testing
import Foundation
@testable import ArcadeApp
@testable import ArcadeCore
import JiraKit

@MainActor
@Test func savingSummarySucceedsAndClearsInFlight() async throws {
    let model = try makeModel(http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 204, body: Data()),
            .init(status: 200, body: Data(#"{"issues":[],"isLast":true}"#.utf8)),
        ])
    })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    await model.saveSummary(issueKey: "DEMO-1", summary: "새 제목")

    #expect(model.editInFlight.isEmpty)
    #expect(model.editFailures["DEMO-1"] == nil)
}

/// 400이 담아 오는 것은 Jira 응답 본문이고 거기에는 이메일이 섞일 수 있다.
@MainActor
@Test func aRejectedSaveDoesNotQuoteJira() async throws {
    let rejected = #"{"errorMessages":["someone@example.com: summary is too long"]}"#
    let model = try makeModel(http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 400, body: Data(rejected.utf8)),
        ])
    })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    await model.saveSummary(issueKey: "DEMO-1", summary: "새 제목")

    let message = try #require(model.editFailures["DEMO-1"])
    #expect(!message.contains("someone@example.com"))
    #expect(!message.contains("too long"))
}

@MainActor
@Test func dismissingTheFailureUnlocksTheField() async throws {
    let model = try makeModel(http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 400, body: Data("{}".utf8)),
        ])
    })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])
    await model.saveSummary(issueKey: "DEMO-1", summary: "새 제목")
    #expect(model.editFailures["DEMO-1"] != nil)

    model.dismissEditFailure(issueKey: "DEMO-1")

    #expect(model.editFailures["DEMO-1"] == nil)
}

/// 로그아웃은 "Jira와 더 이상 말하지 않는다"이다. 진행 중인 저장을 남겨두면
/// 다음 계정의 client로 옛 티켓 키에 쓸 수 있다.
@MainActor
@Test func signOutClearsEditStateAndTasks() async throws {
    let model = try makeModel(http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 400, body: Data("{}".utf8)),
        ])
    })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])
    await model.saveSummary(issueKey: "DEMO-1", summary: "새 제목")
    #expect(model.editFailures["DEMO-1"] != nil)

    await model.signOut()

    #expect(model.editFailures.isEmpty)
    #expect(model.editInFlight.isEmpty)
    #expect(model.editTaskCountForTesting == 0)
    #expect(model.detailState == .idle)
}

/// 401은 만료 배너가 이미 같은 사실을 말한다. 시트에도 실패를 띄우면 인증 문제가
/// 두 번 보이고 사용자는 티켓 문제와 세션 문제를 구분하지 못한다.
@MainActor
@Test func anExpiredTokenMovesToExpiredWithoutAFieldFailure() async throws {
    let model = try makeModel(http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 401, body: Data("{}".utf8)),
        ])
    })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    await model.saveSummary(issueKey: "DEMO-1", summary: "새 제목")

    #expect(model.phase == .expired)
    #expect(model.editFailures["DEMO-1"] == nil)
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter IssueEditTests`

Expected: FAIL — 메서드가 없다.

- [ ] **Step 3: 상태와 저장을 더한다**

`AppModel`의 상태 선언에 더한다.

```swift
    /// 저장이 날아가 있는 티켓. 버튼을 잠가 이중 제출을 막는다 — 댓글 POST는
    /// 멱등이 아니라 두 번 누르면 댓글이 둘이 된다.
    public private(set) var editInFlight: Set<String> = []
    /// 화면에 그릴 실패 문구. **Jira가 준 사유가 들어 있지 않다.**
    public private(set) var editFailures: [String: String] = [:]
    private var editTasks: [String: Task<Void, Never>] = [:]

    var editTaskCountForTesting: Int { editTasks.count }
```

`openDetail` 아래에 더한다.

```swift
    /// 제목을 저장한다.
    ///
    /// 취소 창을 두지 않는 이유: 전이는 한 번 클릭이라 오조작이 쉽지만, 텍스트는
    /// 입력과 저장 버튼에 이미 숙고가 들어 있다.
    ///
    /// **충돌은 감지하지 않는다.** Jira Cloud의 `PUT /issue`에는 낙관적 잠금이 없어
    /// 409도 412도 오지 않는다. Jira 웹과 같은 마지막-쓰기-승리다.
    public func saveSummary(issueKey: String, summary: String) async {
        guard let client else { return }
        // 미러에 없는 티켓은 화면에도 없다 — 사용자가 고를 수 있는 상황이 아니다.
        guard issues.contains(where: { $0.key == issueKey }) else { return }
        guard !editInFlight.contains(issueKey) else { return }

        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        editInFlight.insert(issueKey)
        editFailures[issueKey] = nil
        let generation = syncGeneration

        // `AppModel`은 `@Observable @MainActor`다. 이 `Task`는 같은 격리를 물려받으므로
        // 안에서 상태를 직접 만져도 되고, 정리를 중첩 `Task`로 미루지 않아 완료 시점이
        // 확정된다 — 미루면 `await task.value`가 돌아온 뒤에도 `editInFlight`가
        // 잠깐 남아 있어 호출자가 본 상태와 실제가 어긋난다.
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishEdit(issueKey: issueKey) }
            do {
                try await client.updateSummary(issueKey: issueKey, summary: trimmed)
            } catch JiraError.unauthorized {
                // 만료 배너가 이미 같은 사실을 말한다. 시트에도 실패를 띄우면 인증
                // 문제가 두 번 보이고, 사용자는 티켓 문제와 세션 문제를 구분하지 못한다.
                if generation == self.syncGeneration { self.phase = .expired }
                return
            } catch {
                if generation == self.syncGeneration {
                    self.editFailures[issueKey] = Self.editFailureMessage(error)
                }
                return
            }
            // 저장하는 동안 계정이 바뀌었으면 이 결과는 남의 것이다.
            guard generation == self.syncGeneration else { return }
            // XP를 직접 주지 않는다. 동기화가 관측해 여느 이벤트와 똑같이 처리한다 —
            // 점수가 관측 로그의 순수 함수라는 불변을 지키는 유일한 방법이다.
            // 제목 수정은 미러의 summary를 갱신해야 카드의 제목이 맞는다.
            await self.syncNow(reason: .manual)
        }
        editTasks[issueKey] = task
        await task.value
    }

    public func dismissEditFailure(issueKey: String) {
        editFailures[issueKey] = nil
    }

    private func finishEdit(issueKey: String) {
        editInFlight.remove(issueKey)
        editTasks[issueKey] = nil
    }

    /// 화면에 띄울 실패 안내. **Jira가 준 사유를 옮기지 않는다.**
    ///
    /// 400은 `JiraError.transitionRejected(reason:)`로 들어오고 그 `reason`은 Jira
    /// 응답의 `errorMessages`를 그대로 담는다. 본문에는 이메일이 섞일 수 있다.
    private static func editFailureMessage(_ error: any Error) -> String {
        switch error {
        case JiraError.transitionRejected:
            return "Jira가 이 수정을 받지 않았습니다. Jira에서 확인해 주세요."
        case JiraError.offline:
            return "연결되지 않았습니다. 다시 시도해 주세요."
        case JiraError.forbidden:
            return "이 티켓을 수정할 권한이 없습니다."
        case JiraError.notFound:
            return "티켓을 찾을 수 없습니다."
        default:
            return "저장하지 못했습니다. 다시 시도해 주세요."
        }
    }
```

**주의:** `AppModel`은 `@Observable @MainActor`로 선언돼 있다(`AppModel.swift:6`). 안쪽 `Task`가 그 격리를 물려받으므로 `self.` 로 상태를 직접 만지면 되고, 별도 `await`이나 중첩 `Task`가 필요하지 않다.

- [ ] **Step 4: `signOut()`이 편집 상태를 지우게 한다**

`signOut()`의 전이 정리 바로 아래에 더한다.

```swift
        // 진행 중인 저장도 로그아웃의 대상이다. 남겨두면 다음 계정으로 로그인한 뒤
        // 완료 핸들러가 그 계정의 화면에 실패를 그리거나 동기화를 유발한다.
        // 전이 타이머와 같은 이유이며, 같은 사고가 실제로 출하된 적이 있다.
        editTasks.values.forEach { $0.cancel() }
        editTasks = [:]
        editInFlight = []
        editFailures = [:]
        detailState = .idle
```

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`

Expected: 전부 통과. 기존 로그인·전이 테스트가 응답 순서 때문에 깨지면 **스크립트에 응답을 더해** 고친다. 단언을 고치지 않는다.

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift Packages/Jirarcade/Tests/ArcadeAppTests/IssueEditTests.swift
git commit -m "feat: 제목을 저장하고 편집 상태를 계정 경계에 묶는다"
```

---

### Task 9: 댓글 등록

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/IssueEditTests.swift`

**Interfaces:**
- Consumes: `JiraClient.addComment` (Task 6), `ADFBuilder.paragraphs` (Task 3), Task 8의 생명주기
- Produces: `AppModel.postComment(issueKey: String, text: String) async`

**전제:** Task 1이 이미 들어가 있어야 한다. `.touched`가 아직 XP를 준다면 이 기능이 파밍 경로를 연다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/ArcadeAppTests/IssueEditTests.swift`에 더한다.

```swift
@MainActor
@Test func postingACommentSucceeds() async throws {
    let model = try makeModel(http: {
        ScriptedHTTP([
            .init(status: 200, body: Data(myselfBody.utf8)),
            .init(status: 201, body: Data("{}".utf8)),
            .init(status: 200, body: Data(#"{"issues":[],"isLast":true}"#.utf8)),
        ])
    })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    await model.postComment(issueKey: "DEMO-1", text: "확인했습니다")

    #expect(model.editInFlight.isEmpty)
    #expect(model.editFailures["DEMO-1"] == nil)
}

/// 빈 댓글은 보내지 않는다. 공백만 친 뒤 저장을 누른 것은 등록 의사가 아니다.
@MainActor
@Test func whitespaceOnlyCommentIsNotSent() async throws {
    let http = ScriptedHTTP([.init(status: 200, body: Data(myselfBody.utf8))])
    let model = try makeModel(http: { http })
    await model.signIn(site: "example.atlassian.net", email: "a@example.com", token: "t")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    await model.postComment(issueKey: "DEMO-1", text: "   \n  ")

    // 큐가 비었으므로 요청이 하나라도 더 나갔다면 URLError로 실패했을 것이다.
    #expect(model.editFailures["DEMO-1"] == nil)
    #expect(model.editInFlight.isEmpty)
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter IssueEditTests`

Expected: FAIL — `postComment`가 없다.

- [ ] **Step 3: 구현한다**

`saveSummary` 아래에 더한다. Task 8이 만든 `finishEdit(issueKey:)`와 `editFailureMessage(_:)`를 그대로 쓴다.

```swift
    /// 댓글을 등록한다.
    ///
    /// 보내는 ADF는 우리가 처음부터 만든다 — 읽어온 문서를 되돌려 보내지 않으므로
    /// 왕복 손실이 없다.
    public func postComment(issueKey: String, text: String) async {
        guard let client else { return }
        guard issues.contains(where: { $0.key == issueKey }) else { return }
        guard !editInFlight.contains(issueKey) else { return }
        guard let document = ADFBuilder.paragraphs(from: text) else { return }

        editInFlight.insert(issueKey)
        editFailures[issueKey] = nil
        let generation = syncGeneration

        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishEdit(issueKey: issueKey) }
            do {
                try await client.addComment(issueKey: issueKey, body: document)
            } catch JiraError.unauthorized {
                if generation == self.syncGeneration { self.phase = .expired }
                return
            } catch {
                if generation == self.syncGeneration {
                    self.editFailures[issueKey] = Self.editFailureMessage(error)
                }
                return
            }
            guard generation == self.syncGeneration else { return }
            await self.syncNow(reason: .manual)
        }
        editTasks[issueKey] = task
        await task.value
    }
```

**주의:** Task 8과 같은 격리 형태다. `AppModel`이 `@MainActor`이므로 `Task` 안에서 상태를 직접 만진다.

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`

Expected: 전부 통과.

- [ ] **Step 5: 채점이 움직이지 않았는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter "ScoreEngine|XpAwarder|Hygiene|AbuseGuard|EndToEnd"`

Expected: 전부 통과. 댓글 기능은 표시·쓰기 전용이며 채점 규칙에 들어가지 않는다.

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift Packages/Jirarcade/Tests/ArcadeAppTests/IssueEditTests.swift
git commit -m "feat: 앱에서 댓글을 등록한다"
```

---

### Task 10: 시트 화면

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeUI/TicketDetail/TicketDetailSheet.swift`
- Create: `Packages/Jirarcade/Sources/ArcadeUI/TicketDetail/CommentListView.swift`

**Interfaces:**
- Consumes: `AppModel.detailState`, `.openDetail`, `.closeDetail`, `.saveSummary`, `.postComment`, `.editInFlight`, `.editFailures`, `.dismissEditFailure`
- Produces: `TicketDetailSheet(issueKey:model:)`

**`ArcadeUI`에는 테스트 타깃이 없다.** 이 파일에는 판단을 두지 않는다 — 상태를 읽어 그리고, 버튼이 `AppModel`의 메서드를 부르는 것이 전부다. `if`는 "무엇을 보여줄지"가 아니라 "어느 상태인지"만 가른다.

- [ ] **Step 1: 댓글 목록을 만든다**

`Sources/ArcadeUI/TicketDetail/CommentListView.swift`:

```swift
import SwiftUI
import ArcadeApp

struct CommentListView: View {
    @Environment(\.arcadeTheme) private var theme
    let comments: [CommentView]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(comment.authorName)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(theme.inkSecondary)
                        Text(comment.created, style: .date)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(theme.inkTertiary)
                    }
                    Text(comment.text)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.inkPrimary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
```

**주의:** 테마 토큰 이름은 `ArcadeTheme.swift` 기준으로 `inkPrimary`·`inkSecondary`·`inkTertiary`다.

- [ ] **Step 2: 시트를 만든다**

`Sources/ArcadeUI/TicketDetail/TicketDetailSheet.swift`:

```swift
import SwiftUI
import ArcadeApp

/// 티켓 하나를 읽고, 제목을 고치고, 댓글을 단다.
///
/// 판단은 전부 `AppModel`에 있다 — 이 파일에는 테스트가 닿지 않으므로 무엇을
/// 보여줄지 고르는 코드를 두지 않는다.
struct TicketDetailSheet: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let issueKey: String
    let model: AppModel

    @State private var summaryDraft = ""
    @State private var commentDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 520, height: 560)
        .background(theme.surfaceBase)
        .task { await model.openDetail(issueKey: issueKey) }
        .onDisappear { model.closeDetail() }
    }

    private var header: some View {
        HStack {
            Text(issueKey)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.inkPrimary)
            Spacer()
            Button("닫기") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.inkTertiary)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch model.detailState {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.danger)
                Button("다시 시도") { Task { await model.openDetail(issueKey: issueKey) } }
                    .font(.system(size: 11, design: .monospaced))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let detail):
            loaded(detail)
        }
    }

    private func loaded(_ detail: IssueDetailView) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let failure = model.editFailures[issueKey] {
                    HStack {
                        Text(failure)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.danger)
                        Spacer()
                        Button("닫기") { model.dismissEditFailure(issueKey: issueKey) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(theme.inkTertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("제목").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.inkTertiary)
                    TextField("", text: $summaryDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                    Button("제목 저장") {
                        Task { await model.saveSummary(issueKey: issueKey, summary: summaryDraft) }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .disabled(model.editInFlight.contains(issueKey)
                              || summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || summaryDraft == detail.summary)
                }
                .onAppear { summaryDraft = detail.summary }

                VStack(alignment: .leading, spacing: 6) {
                    Text("본문").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.inkTertiary)
                    Text(detail.descriptionText.isEmpty ? "본문이 없습니다" : detail.descriptionText)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.inkPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("댓글").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.inkTertiary)
                    CommentListView(comments: detail.comments)
                    TextEditor(text: $commentDraft)
                        .font(.system(size: 12))
                        .frame(height: 72)
                        .border(theme.inkTertiary.opacity(0.3))
                    Button("댓글 등록") {
                        Task {
                            await model.postComment(issueKey: issueKey, text: commentDraft)
                            commentDraft = ""
                            await model.openDetail(issueKey: issueKey)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .disabled(model.editInFlight.contains(issueKey)
                              || commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
        }
    }
}
```

**주의:** 테마 토큰은 `ArcadeTheme.swift`에 `surfaceBase`·`surfaceRaised`·`line`·`inkPrimary`·`inkSecondary`·`inkTertiary`·`accent`·`boss`·`danger`·`good`로 정의돼 있다. 이 이름들만 쓴다. `AppModel`이 `@Observable`이면 `let model: AppModel`로 충분하다 — `QuestBoardView`가 어떻게 받는지 보고 같은 형태로 맞춘다.

- [ ] **Step 3: 빌드가 통과하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift build && swift test`

Expected: 빌드 성공, 테스트 전부 통과. `ArcadeUI`에는 테스트가 없으므로 개수는 그대로다.

- [ ] **Step 4: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeUI/TicketDetail/
git commit -m "feat: 티켓 상세 시트를 그린다"
```

---

### Task 11: 카드에서 시트를 연다

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/TicketCardView.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/BoardLaneView.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/QuestBoardView.swift`

**Interfaces:**
- Consumes: `TicketDetailSheet` (Task 10)
- Produces: 없음 (배선)

**주의:** 카드에는 이미 `상태 옮기기` 메뉴와 `취소`·`닫기` 버튼이 있다. **카드 전체를 탭 대상으로 만들면 그 버튼들의 클릭을 가로챌 수 있다.** 티켓 키 텍스트만 탭 대상으로 삼는다.

- [ ] **Step 1: 카드에 열기 콜백을 더한다**

`TicketCardView`에 프로퍼티를 더한다.

```swift
    let onOpenDetail: (String) -> Void
```

티켓 키를 그리는 곳(`Text(slot.issue.key)`)을 버튼으로 바꾼다.

```swift
            // 카드 전체가 아니라 키만 탭 대상이다. 카드에는 상태 옮기기 메뉴와
            // 취소·닫기 버튼이 있어, 전체를 제스처로 덮으면 그 클릭을 가로챈다.
            Button { onOpenDetail(slot.issue.key) } label: {
                Text(slot.issue.key)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.inkPrimary)
            }
            .buttonStyle(.plain)
```

- [ ] **Step 2: 레인이 콜백을 넘기게 한다**

`BoardLaneView`에 같은 프로퍼티를 더하고 `TicketCardView(...)` 호출에 넘긴다.

```swift
    let onOpenDetail: (String) -> Void
```

- [ ] **Step 3: 보드가 시트를 띄우게 한다**

`QuestBoardView`에 상태를 더한다.

```swift
    @State private var detailIssueKey: String?
```

레인에 콜백을 넘기고, 뷰 바깥에 시트를 붙인다.

```swift
        .sheet(item: $detailIssueKey) { key in
            TicketDetailSheet(issueKey: key, model: model)
        }
```

`String`은 `Identifiable`이 아니므로 감싸는 타입이 필요하다. 같은 파일 안에 둔다.

```swift
/// `sheet(item:)`이 `Identifiable`을 요구한다. 티켓 키 자체가 식별자이므로
/// 얇게 감싸기만 한다.
private struct DetailTarget: Identifiable {
    let id: String
}
```

그리고 상태를 `@State private var detailTarget: DetailTarget?`로 두고, 콜백에서 `detailTarget = DetailTarget(id: key)`를 넣는다.

- [ ] **Step 4: 빌드와 테스트를 돌린다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift build && swift test`

Expected: 빌드 성공, 전부 통과. `QuestBoardCabinet`이나 프리뷰가 `TicketCardView`/`BoardLaneView`를 직접 만든다면 새 인자를 넘겨야 컴파일된다 — `rg "TicketCardView\(|BoardLaneView\(" Sources/ArcadeUI/`로 전부 찾는다.

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/
git commit -m "feat: 카드의 티켓 키를 눌러 상세를 연다"
```

---

### Task 12: 완성 정의 확인과 README

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/records/2026-08-21-quest-board-visual-checklist.md`

**Interfaces:**
- Consumes: 전체
- Produces: 없음

- [ ] **Step 1: 완성 정의를 하나씩 코드와 대조한다**

스펙의 완성 정의를 읽고 **각 항목을 실제 코드나 테스트로 확인한다.** 통과로 표시하는 항목마다 무엇을 읽었거나 돌렸는지 적는다. 확인할 수 없는 항목은 **통과가 아니라 미확인으로 적는다.**

```
docs/superpowers/specs/2026-08-24-ticket-detail-design.md 의 §11
```

- [ ] **Step 2: 채점 불변을 확인한다**

Run:
```bash
cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade
swift test --filter "ScoreEngine|XpAwarder|Hygiene|AbuseGuard|EndToEnd"
rg "descriptionText|CommentView|IssueDetail|ADFRenderer" Sources/ArcadeCore/Rules/ Sources/ArcadeCore/Backfill/
```

Expected: 테스트 전부 통과. `rg`는 **아무것도 찾지 못해야 한다** — 상세·댓글 타입이 채점이나 백필에 닿으면 안 된다.

- [ ] **Step 3: 시각 검증 체크리스트에 항목을 더한다**

`ArcadeUI`에는 테스트 타깃이 없고, 이 저장소의 답은 시각 체크리스트다. 기존 절 구조와 문체에 맞춰 더한다.

- 카드의 티켓 키를 누르면 시트가 열린다. 카드의 `상태 옮기기` 메뉴와 `취소`·`닫기` 버튼은 그대로 동작한다
- 본문에 표·첨부·모르는 서식이 있으면 자리표시자가 보이고 내용이 조용히 사라지지 않는다
- 본문이 없는 티켓은 "본문이 없습니다"가 보인다
- 댓글이 최신순으로 보인다
- 제목을 고치면 저장 버튼이 활성화되고, 저장하면 카드의 제목이 따라 바뀐다
- 저장 중에는 버튼이 잠긴다
- 저장 실패 문구에 Jira 응답 본문이 들어 있지 않다
- 댓글을 등록하면 목록에 나타나고 입력창이 비워진다

- [ ] **Step 4: README를 갱신한다**

"동작합니다" 목록에 더한다.

```
- 카드에서 티켓 상세를 열어 본문과 최근 댓글을 읽기
- 제목 수정과 댓글 등록
```

**주의:** README에 실제 사이트 주소·프로젝트 키·커스텀 상태명을 넣지 않는다.

- [ ] **Step 5: 전체 테스트를 돌린다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`

Expected: 전부 통과.

- [ ] **Step 6: 커밋**

```bash
git add README.md docs/superpowers/records/
git commit -m "docs: 티켓 상세와 댓글을 동작하는 기능으로 옮긴다"
```

---

## 계획 자체 점검

**스펙 커버리지**

| 스펙 절 | 태스크 |
|---|---|
| §2.1 touched wake XP 제거 | Task 1 |
| §2.2 연속 기록 회귀 | Task 1 Step 5 |
| §2.3 순서 제약 | Task 1이 첫 번째, Task 9가 그 뒤 |
| §3 데이터 경계 | Task 7 (미러 미접촉), Task 12 Step 2 (확인) |
| §3.1 표시 정체일 각주 | 동작 변경 없음. 스펙에 기록됨 |
| §4 ADF 렌더러 | Task 2, Task 4 |
| §4.1 노드별 처리 | Task 4 |
| §5.1 쓰기 엔드포인트 | Task 6 |
| §5.1 입력 → ADF 규칙 | Task 3 |
| §5.2 마지막 쓰기 승리 | Task 8 (충돌 감지 없음, 주석에 명시) |
| §5.3 생명주기 | Task 8 |
| §5.4 쓰기 뒤 동기화 | Task 8, Task 9 |
| §6 실패 처리 | Task 7 (조회), Task 8 (쓰기) |
| §7 댓글 로딩 | Task 6 (`orderBy=-created`), Task 7 (20건) |
| §8 화면 | Task 10, Task 11 |
| §9 JiraKit 표면 | Task 2, 3, 5, 6 |
| §10 테스트 전략 | 각 태스크 |
| §11 완성 정의 | Task 12 |

**남는 위험**

- Task 8·9는 `AppModel`이 `@MainActor`라는 사실에 기대어 `Task` 안에서 상태를 직접 만진다(`AppModel.swift:6`에서 확인). 이 선언이 바뀌면 두 태스크의 코드가 컴파일되지 않는다.
- Task 7·8·9는 로그인 경로에 이어지는 HTTP 호출을 추가한다. `ScriptedHTTP`는 응답을 **순서대로** 돌려주므로 기존 테스트가 깨질 수 있다. 그때는 **스크립트에 응답을 더해** 고치고 단언은 건드리지 않는다.
- 테마 토큰 이름은 확인해 반영했다(`ArcadeTheme.swift`): `surfaceBase`·`surfaceRaised`·`line`·`inkPrimary`·`inkSecondary`·`inkTertiary`·`accent`·`boss`·`danger`·`good`.
