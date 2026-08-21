# 퀘스트 보드 (계획 2b-1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 내 미완료 티켓을 단계별 레인에 정체일 순으로 늘어놓고, 카드에서 바로 상태를 옮길 수 있는 퀘스트 보드 캐비닛을 만든다.

**Architecture:** 배치 계산 전부(`BoardAxis`·`LanePacker`·`BoardLayout`)가 `ArcadeCore`의 순수 함수다 — `ArcadeUI`에 테스트 타깃이 없으므로 뷰에 판단을 남기면 무커버가 된다. 뷰는 좌표를 받아 그리기만 한다. 전이는 `ArcadeApp`이 티켓별 타이머로 5초를 기다렸다가 요청을 보내고, 성공하면 XP를 직접 주는 대신 동기화를 트리거해 diff가 이벤트를 만들게 한다.

**Tech Stack:** Swift 6.2 / SwiftUI / Observation(`@Observable`) / Swift Testing

**Spec:** `docs/superpowers/specs/2026-08-21-quest-board-design.md`
**선행 스펙:** `docs/superpowers/specs/2026-08-12-jirarcade-design.md` (v0.1) · `docs/superpowers/specs/2026-08-14-app-shell-design.md` (앱 셸)

## Global Constraints

- 스펙 원본은 위 세 문서다. 충돌 시 퀘스트 보드 스펙(2026-08-21)이 우선한다.
- 모듈 의존 방향은 단방향이다: `ArcadeUI → ArcadeApp → ArcadeCore → JiraKit`. 역방향 import는 금지한다.
- **`ArcadeApp`은 SwiftUI를 import하지 않는다.** `ModuleBoundaryTests.arcadeAppNeverImportsSwiftUI`가 강제한다.
- **`ArcadeUI`의 뷰 코드에 색 리터럴을 두지 않는다.** 모든 색은 `@Environment(\.arcadeTheme)`에서 온다. `ModuleBoundaryTests.viewsUseThemeTokensRatherThanColorLiterals`가 `Color.red` 계열, `.primary`/`.secondary`, `#RRGGBB` 문자열, `Color(red:)`/`.init(red:)` 생성자를 전부 막는다.
- 시간에 의존하는 모든 공개 함수는 `now: Date`를 받거나 주입된 `clock`을 쓴다. 본문에서 `Date()`를 호출하지 않는다.
- `Calendar`는 주입받은 것만 쓴다. `Calendar.current` 직접 참조 금지.
- 게임 규칙 상수는 `RuleSet`에서 읽는다. 앱 동작 설정은 `AppSettings`에서 읽는다 — 둘을 섞지 않는다.
- **Jira 응답 본문 조각이 화면·로그·저장소에 닿지 않는다.** 실패 문자열은 `redactedErrorDescription(_:)`을 거치거나 앱이 직접 쓴 문구만 쓴다. `JiraError.transitionRejected(reason:)`의 `reason`을 화면에 옮기지 않는다.
- 조직 특정 정보(실제 사이트 주소·프로젝트 키·커스텀 상태명)를 코드나 테스트에 넣지 않는다. 테스트는 `example.atlassian.net`, `DEMO-`, `demoWorkflow`의 영문 상태명을 쓴다. `ModuleBoundaryTests.onlyTheExampleJiraSiteAppearsAnywhere`가 강제한다.
- 테스트는 Swift Testing(`@Test` / `#expect`)을 쓴다. XCTest를 새로 작성하지 않는다.
- 정렬은 어디서든 결정적이어야 한다. Swift의 `sorted(by:)`는 안정 정렬이 아니므로 동률 타이브레이크를 명시한다.
- 각 태스크는 `swift test` 통과 후 커밋으로 끝난다.

## File Structure

```
Packages/Jirarcade/
├── Sources/
│   ├── ArcadeCore/
│   │   ├── Domain/
│   │   │   └── StatusTimeline.swift        ← 신규. 이벤트 로그 → 상태 진입 시각
│   │   ├── Board/                          ← 신규 디렉터리
│   │   │   ├── BoardAxis.swift             눈금 + 구간별 선형 위치
│   │   │   ├── LanePacker.swift            겹침 해소 (row 배정)
│   │   │   └── BoardLayout.swift           레인 구성 · 미매핑 분리 · DueState
│   │   └── Rules/
│   │       └── ScoreEngine.swift           ← 수정. StatusTimeline.apply를 쓴다
│   ├── ArcadeApp/
│   │   ├── AppSettings.swift               ← 수정. transitionUndoWindow 추가
│   │   ├── PendingTransition.swift         ← 신규. 대기 중인 전이 값 타입
│   │   └── AppModel.swift                  ← 수정. 보드 상태 + 전이 파이프라인
│   └── ArcadeUI/
│       ├── Cabinet.swift                   ← 수정. presentation 추가
│       ├── ArcadeFloorView.swift           ← 수정. 전체 화면 전환
│       ├── AtlassianLinks.swift            ← 수정. issue(key:site:) 추가
│       └── QuestBoard/                     ← 신규 디렉터리
│           ├── QuestBoardCabinet.swift     Cabinet 준수 + 마퀴 줄
│           ├── QuestBoardView.swift        전체 화면 골격 (헤더 · HUD · 레인 스크롤)
│           ├── BoardHUDView.swift          LV · XP · 연속 · HP · 위생 · 다음 한 걸음
│           ├── BoardLaneView.swift         레인 하나 — 축 + 슬롯 배치
│           ├── BoardAxisView.swift         눈금선과 라벨
│           ├── TicketCardView.swift        카드 하나 + 전이 메뉴 + 대기 표시
│           └── UnmappedLaneView.swift      매핑되지 않은 상태의 티켓
└── Tests/
    ├── ArcadeCoreTests/
    │   ├── StatusTimelineTests.swift       ← 신규
    │   ├── BoardAxisTests.swift            ← 신규
    │   ├── LanePackerTests.swift           ← 신규
    │   └── BoardLayoutTests.swift          ← 신규
    └── ArcadeAppTests/
        ├── BoardStateTests.swift           ← 신규
        └── TransitionTests.swift           ← 신규
```

`ArcadeUI/QuestBoard/`를 디렉터리로 나누는 이유: 보드는 뷰가 일곱 개이고 `ArcadeUI` 루트에
전부 풀어 놓으면 기존 여덟 개 파일과 섞여 어느 것이 셸이고 어느 것이 캐비닛인지 사라진다.
SPM은 디렉터리 구조를 모듈에 반영하지 않으므로 import는 그대로다.

---
### Task 1: `StatusTimeline` — 이벤트 로그에서 상태 진입 시각

정체일은 "현재 상태에 들어간 시각"에서 나온다. 그 값은 지금 `ScoreEngine.recompute`의
지역 변수로만 존재하고(`ScoreEngine.swift:64`) 밖에서 읽을 방법이 없다.

갱신 규칙 한 줄을 `StatusTimeline.apply`로 추출해 `ScoreEngine`이 그것을 쓰게 한다.
그러면 규칙이 진짜로 한 곳에만 있게 되어 "두 경로가 같은 답을 낸다"를 테스트로 쫓을
필요가 없어진다 — 구조적으로 같아진다.

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Domain/StatusTimeline.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Rules/ScoreEngine.swift:77-79`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/StatusTimelineTests.swift`

**Interfaces:**
- Consumes: `DomainEvent`, `EventKind` (`ArcadeCore/Domain/DomainEvent.swift`)
- Produces:
  - `StatusTimeline.apply(_ event: DomainEvent, to map: inout [String: Date])`
  - `StatusTimeline.latestStatusEntry(from events: [DomainEvent]) -> [String: Date]`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Packages/Jirarcade/Tests/ArcadeCoreTests/StatusTimelineTests.swift`:

```swift
import Testing
import Foundation
@testable import ArcadeCore

private let base = iso("2026-08-01T00:00:00Z")

private func event(
    _ key: String, _ kind: EventKind, at offset: Double
) -> DomainEvent {
    DomainEvent(
        issueKey: key, kind: kind, fromStatus: nil, toStatus: nil,
        observedAt: base.addingTimeInterval(days(offset)), actorAccountId: "acc-me"
    )
}

@Test func takesTheLatestStatusChangePerIssue() {
    let map = StatusTimeline.latestStatusEntry(from: [
        event("DEMO-1", .statusChanged, at: 1),
        event("DEMO-1", .statusChanged, at: 5),
        event("DEMO-2", .statusChanged, at: 3),
    ])

    #expect(map["DEMO-1"] == base.addingTimeInterval(days(5)))
    #expect(map["DEMO-2"] == base.addingTimeInterval(days(3)))
}

/// 상태가 바뀌지 않은 변화는 진입 시각을 갱신하지 않는다. `touched`가 갱신하면
/// 댓글 한 줄로 정체일이 0으로 리셋되어, 이 앱이 재려는 것 자체가 사라진다.
@Test func ignoresEventsThatAreNotStatusChanges() {
    let map = StatusTimeline.latestStatusEntry(from: [
        event("DEMO-1", .statusChanged, at: 1),
        event("DEMO-1", .touched, at: 9),
        event("DEMO-1", .dueDateChanged, at: 9),
        event("DEMO-1", .appeared, at: 9),
        event("DEMO-1", .vanished, at: 9),
    ])

    #expect(map["DEMO-1"] == base.addingTimeInterval(days(1)))
}

/// 이벤트 로그가 시간순이라는 보장은 없다. `ArcadeStore.loadEvents()`의 정렬은
/// 계약이 아니고, 백필은 과거 이벤트를 나중에 넣는다.
@Test func doesNotDependOnInputOrder() {
    let scrambled = [
        event("DEMO-1", .statusChanged, at: 5),
        event("DEMO-1", .statusChanged, at: 1),
        event("DEMO-1", .statusChanged, at: 3),
    ]

    #expect(StatusTimeline.latestStatusEntry(from: scrambled)["DEMO-1"]
            == base.addingTimeInterval(days(5)))
}

@Test func hasNoEntryForIssuesThatNeverChangedStatus() {
    let map = StatusTimeline.latestStatusEntry(from: [event("DEMO-1", .appeared, at: 1)])

    #expect(map["DEMO-1"] == nil)
}

@Test func handlesAnEmptyLog() {
    #expect(StatusTimeline.latestStatusEntry(from: []).isEmpty)
}

/// `ScoreEngine`이 순회 도중 부르는 형태. 이 함수가 규칙의 유일한 정의다.
@Test func applyUpdatesOnlyOnStatusChange() {
    var map: [String: Date] = [:]

    StatusTimeline.apply(event("DEMO-1", .touched, at: 1), to: &map)
    #expect(map.isEmpty)

    StatusTimeline.apply(event("DEMO-1", .statusChanged, at: 2), to: &map)
    #expect(map["DEMO-1"] == base.addingTimeInterval(days(2)))
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter StatusTimeline
```

기대: 컴파일 실패 — `cannot find 'StatusTimeline' in scope`

- [ ] **Step 3: 최소 구현을 쓴다**

`Packages/Jirarcade/Sources/ArcadeCore/Domain/StatusTimeline.swift`:

```swift
import Foundation

/// 이벤트 로그에서 티켓별 "현재 상태에 들어간 시각"을 재구성한다.
///
/// 이 값이 정체 판정의 기준선이다. `StagnationClassifier`는 `statusEnteredAt`이 nil이면
/// `jiraUpdatedAt`으로 폴백하는데, 그러면 댓글·워크로그도 기준선을 밀어 정체일이 실제보다
/// 짧게 나온다. 이벤트 로그가 있으면 언제나 그쪽이 정확하다.
public enum StatusTimeline {
    /// 이벤트 하나를 반영한다. **갱신 규칙의 유일한 정의**이며 `ScoreEngine.recompute`의
    /// 순회도 이것을 부른다.
    ///
    /// `.statusChanged`만 기준선을 옮긴다. `.touched`가 옮기면 댓글 한 줄로 정체일이
    /// 0이 되어, 이 앱이 재려는 것 자체가 사라진다.
    ///
    /// **덮어쓰기 전에 비교하지 않는다.** 호출자가 시간순으로 넣는다는 전제이며,
    /// `ScoreEngine`은 정렬된 배열을 순회하고 `latestStatusEntry`는 스스로 정렬한다.
    public static func apply(_ event: DomainEvent, to map: inout [String: Date]) {
        guard event.kind == .statusChanged else { return }
        map[event.issueKey] = event.observedAt
    }

    /// 로그 전체를 반영한 **최종** 맵. 보드가 정체일을 계산할 때 쓴다.
    ///
    /// 입력 순서를 신뢰하지 않고 정렬한다 — `ArcadeStore.loadEvents()`의 순서는 계약이
    /// 아니고, 백필은 과거 이벤트를 나중에 넣는다. 동률은 순서가 뒤바뀌어도 같은 값을
    /// 쓰므로 타이브레이크가 필요 없다.
    public static func latestStatusEntry(from events: [DomainEvent]) -> [String: Date] {
        var map: [String: Date] = [:]
        for event in events.sorted(by: { $0.observedAt < $1.observedAt }) {
            apply(event, to: &map)
        }
        return map
    }
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter StatusTimeline
```

기대: 6 tests PASS

- [ ] **Step 5: `ScoreEngine`이 같은 규칙을 쓰게 한다**

`Packages/Jirarcade/Sources/ArcadeCore/Rules/ScoreEngine.swift`에서 다음 세 줄을

```swift
            if event.kind == .statusChanged {
                statusEnteredAt[event.issueKey] = event.observedAt
            }
```

이렇게 바꾼다:

```swift
            // 갱신 규칙은 StatusTimeline이 유일하게 정의한다. 여기에 규칙을 복사해 두면
            // 보드가 쓰는 최종값과 채점이 쓰는 시점별 값이 서로 다른 규칙으로 갈릴 수 있다.
            StatusTimeline.apply(event, to: &statusEnteredAt)
```

- [ ] **Step 6: 기존 테스트가 여전히 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test
```

기대: 전체 PASS (기존 221개 + 신규 6개). `ScoreEngineTests`·`XpAwarderTests`·`EndToEndTests`가
깨지면 `apply`의 조건이 원래 코드와 다른 것이다 — 되돌려 비교할 것.

- [ ] **Step 7: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Domain/StatusTimeline.swift \
        Packages/Jirarcade/Sources/ArcadeCore/Rules/ScoreEngine.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/StatusTimelineTests.swift
git commit -m "feat: 이벤트 로그에서 상태 진입 시각을 뽑는 StatusTimeline

정체일의 기준선은 ScoreEngine.recompute의 지역 변수로만 존재해 밖에서 읽을 수
없었다. 갱신 규칙을 apply()로 추출해 ScoreEngine이 그것을 쓰게 하면 규칙이 한
곳에만 있게 되고, 보드가 쓰는 최종값과 채점이 쓰는 시점별 값이 갈릴 수 없다."
```

---

### Task 2: `BoardAxis` — 눈금과 구간별 선형 위치

축 눈금은 `RuleSet`의 등급 경계값이다. 눈금이 곧 경계값이면 "이 티켓은 왜 보스인가"에
화면이 스스로 답한다 — 세 번째 눈금을 넘었기 때문이다.

위치는 구간별 선형이다. `days / raidDays`로 단순 매핑하면 0–7일 구간이 축의 15%인데
실제 티켓 대부분이 거기 있어, 다수가 왼쪽 끝에 뭉쳐 서로를 가리고 화면의 85%가 빈다.

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Board/BoardAxis.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/BoardAxisTests.swift`

**Interfaces:**
- Consumes: `RuleSet` (`staleDays`, `bossDays`, `raidDays`)
- Produces:
  - `struct AxisTick { let days: Int; let position: Double; let isTerminal: Bool }`
  - `BoardAxis.ticks(rules: RuleSet) -> [AxisTick]`
  - `BoardAxis.position(forDays days: Int, rules: RuleSet) -> Double`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Packages/Jirarcade/Tests/ArcadeCoreTests/BoardAxisTests.swift`:

```swift
import Testing
import Foundation
@testable import ArcadeCore

/// 눈금은 RuleSet의 등급 경계값이다. 임의의 눈금(0/10/20/30)을 쓰면 화면이 등급과
/// 무관한 눈금을 말하면서 카드에는 BOSS라고 적는 두 개의 설명을 갖게 된다.
@Test func ticksComeFromTheRuleSetBoundaries() {
    let ticks = BoardAxis.ticks(rules: .default)

    #expect(ticks.map(\.days) == [0, 7, 21, 45])
    #expect(ticks.last?.isTerminal == true)
    #expect(ticks.dropLast().allSatisfy { !$0.isTerminal })
}

@Test func ticksAreEvenlySpacedAcrossTheAxis() {
    let positions = BoardAxis.ticks(rules: .default).map(\.position)

    #expect(positions[0] == 0)
    #expect(abs(positions[1] - 1.0 / 3) < 0.0001)
    #expect(abs(positions[2] - 2.0 / 3) < 0.0001)
    #expect(positions[3] == 1)
}

@Test func ticksFollowACustomRuleSet() {
    var rules = RuleSet.default
    rules.staleDays = 3
    rules.bossDays = 10
    rules.raidDays = 20

    #expect(BoardAxis.ticks(rules: rules).map(\.days) == [0, 3, 10, 20])
    #expect(BoardAxis.position(forDays: 10, rules: rules) == 2.0 / 3)
}

/// 각 구간이 축에서 같은 폭을 차지한다. 3일은 0–7 구간의 3/7 지점이므로
/// 축 전체로는 (3/7) × (1/3) ≈ 0.1429다.
@Test func mapsDaysWithinASegmentLinearly() {
    #expect(abs(BoardAxis.position(forDays: 3, rules: .default) - 3.0 / 7 / 3) < 0.0001)
    // 30일은 21–45 구간의 9/24 지점 → 2/3 + (9/24)/3 ≈ 0.7917
    #expect(abs(BoardAxis.position(forDays: 30, rules: .default) - (2.0 / 3 + 9.0 / 24 / 3)) < 0.0001)
}

/// raidDays를 넘는 티켓은 오른쪽 끝에 붙인다. 3년 정체 티켓 하나가 축 전체를 압축해
/// 나머지를 왼쪽 끝에 뭉치게 하는 것을 막는다. 실제 일수는 카드가 그대로 표기한다.
@Test func clampsBeyondTheTerminalBoundary() {
    #expect(BoardAxis.position(forDays: 45, rules: .default) == 1)
    #expect(BoardAxis.position(forDays: 400, rules: .default) == 1)
}

@Test func clampsBelowZero() {
    #expect(BoardAxis.position(forDays: 0, rules: .default) == 0)
    #expect(BoardAxis.position(forDays: -3, rules: .default) == 0)
}

/// RuleSet은 설정 화면에서 JSON으로 편집할 수 있다. 역전되거나 같은 값이 들어와도
/// 위치가 축 밖으로 나가면 안 된다 — 카드가 화면 밖에 그려지거나 0으로 나누게 된다.
@Test func survivesAContradictoryRuleSet() {
    var rules = RuleSet.default
    rules.staleDays = 30
    rules.bossDays = 10
    rules.raidDays = 5

    let ticks = BoardAxis.ticks(rules: rules)
    #expect(ticks.count == 4)
    #expect(ticks.map(\.days) == ticks.map(\.days).sorted())

    for days in [-5, 0, 1, 10, 30, 100] {
        let position = BoardAxis.position(forDays: days, rules: rules)
        #expect(position >= 0 && position <= 1, "days=\(days) → \(position)")
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter BoardAxis
```

기대: 컴파일 실패 — `cannot find 'BoardAxis' in scope`

- [ ] **Step 3: 최소 구현을 쓴다**

`Packages/Jirarcade/Sources/ArcadeCore/Board/BoardAxis.swift`:

```swift
import Foundation

/// 축 위의 눈금 하나.
public struct AxisTick: Sendable, Equatable {
    public let days: Int
    /// 축 위 0.0…1.0 위치.
    public let position: Double
    /// 마지막 눈금인가. 그 너머가 접혀 있으므로 화면은 "45d+"처럼 그린다.
    public let isTerminal: Bool

    public init(days: Int, position: Double, isTerminal: Bool) {
        self.days = days
        self.position = position
        self.isTerminal = isTerminal
    }
}

/// 정체일을 축 위 위치로 옮긴다.
public enum BoardAxis {
    /// 눈금은 `RuleSet`의 등급 경계값이다: 0 / staleDays / bossDays / raidDays.
    /// 설정에서 규칙을 고치면 축이 따라 움직인다 — 부작용이 아니라 의도다.
    public static func ticks(rules: RuleSet) -> [AxisTick] {
        let bounds = boundaries(rules: rules)
        let last = bounds.count - 1
        return bounds.enumerated().map { index, days in
            AxisTick(days: days,
                     position: Double(index) / Double(last),
                     isTerminal: index == last)
        }
    }

    /// 구간별 선형. 각 눈금 구간이 축에서 **같은 폭**을 차지한다.
    ///
    /// 단순 선형(`days / raidDays`)이 아닌 이유: 0–7일 구간이 축의 15%에 불과한데
    /// 실제 티켓은 대부분 그 구간에 있다. 다수가 왼쪽 끝에 뭉쳐 서로를 가리고 화면의
    /// 85%가 빈다. 등급이 갈리는 구간을 넓게 펼치는 것이 읽고 싶은 것에 맞는 배분이다 —
    /// 45일과 50일의 차이는 이미 둘 다 raid라는 사실 앞에서 작고, 5일과 10일은 등급이 갈린다.
    public static func position(forDays days: Int, rules: RuleSet) -> Double {
        let bounds = boundaries(rules: rules)
        let segments = bounds.count - 1
        guard days > bounds[0] else { return 0 }
        guard days < bounds[segments] else { return 1 }

        for index in 0..<segments where days < bounds[index + 1] {
            let lower = bounds[index], upper = bounds[index + 1]
            let withinSegment = Double(days - lower) / Double(upper - lower)
            return (Double(index) + withinSegment) / Double(segments)
        }
        return 1
    }

    /// 0 / staleDays / bossDays / raidDays를 **단조 증가하도록** 정리한다.
    ///
    /// `RuleSet`은 설정 화면에서 JSON으로 편집할 수 있으므로 역전되거나 같은 값이 올 수
    /// 있다. 그대로 두면 구간 폭이 0이 되어 0으로 나누거나, 음수가 되어 위치가 축 밖으로
    /// 나간다 — 카드가 화면 밖에 그려진다. 앞 경계보다 최소 1 크게 밀어 그 두 경우를 막는다.
    private static func boundaries(rules: RuleSet) -> [Int] {
        var values = [0, rules.staleDays, rules.bossDays, rules.raidDays]
        for index in 1..<values.count {
            values[index] = max(values[index], values[index - 1] + 1)
        }
        return values
    }
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter BoardAxis
```

기대: 7 tests PASS

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Board/BoardAxis.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/BoardAxisTests.swift
git commit -m "feat: 정체 시간축의 눈금과 구간별 선형 위치

눈금을 RuleSet의 등급 경계값에서 끌어와 축이 곧 게임 규칙의 시각화가 되게 한다.
위치는 구간별 선형 — 단순 선형은 0-7일 구간을 축의 15%로 만들어 실제 분포의
대다수를 왼쪽 끝에 뭉치게 한다.

편집 가능한 RuleSet이 역전된 경계값을 줄 수 있으므로 단조 증가하도록 정리한다."
```

---
### Task 3: `BoardLayout` — 레인 구성과 미매핑 분리

티켓을 단계별로 나누고 각각의 정체일·등급·축 위치·마감 상태를 계산한다.
겹침 해소(row 배정)는 Task 4에서 붙이므로 이 태스크에서는 `row`가 전부 0이다.

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Board/BoardLayout.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/BoardLayoutTests.swift`

**Interfaces:**
- Consumes: `BoardAxis.position(forDays:rules:)`, `BoardAxis.ticks(rules:)` (Task 2), `StagnationClassifier`, `WorkflowMap`, `ObservedIssue`, `DueDate`
- Produces:
  - `enum DueState { case none, dueIn(days: Int), overdue(days: Int) }`
  - `struct BoardSlot { issue, daysStagnant, tier, position, row, isApproximate, dueState }`
  - `struct BoardLane { stage, slots, rowCount }`
  - `struct BoardSnapshot { lanes, unmappedIssues, axis }`
  - `BoardLayout.visibleStages: [Stage]`
  - `BoardLayout.snapshot(issues:statusEnteredAt:workflow:rules:minimumSpacing:now:calendar:) -> BoardSnapshot`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Packages/Jirarcade/Tests/ArcadeCoreTests/BoardLayoutTests.swift`:

```swift
import Testing
import Foundation
@testable import ArcadeCore

private let now = iso("2026-08-21T00:00:00Z")

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func snapshot(
    _ issues: [ObservedIssue],
    enteredAt: [String: Date] = [:],
    workflow: WorkflowMap = demoWorkflow,
    spacing: Double = 0
) -> BoardSnapshot {
    BoardLayout.snapshot(
        issues: issues, statusEnteredAt: enteredAt, workflow: workflow,
        rules: .default, minimumSpacing: spacing, now: now, calendar: utc
    )
}

/// `done`은 레인에 넣지 않는다. 동기화 JQL이 `statusCategory != Done`이라 미러에
/// 완료 티켓이 없고, 영구히 빈 레인은 "뭔가 들어와야 하는데 비어 있다"는 잘못된 신호다.
@Test func laysOutTheFourVisibleStagesAndNotDone() {
    let result = snapshot([])

    #expect(result.lanes.map(\.stage) == [.backlog, .active, .review, .verify])
}

@Test func putsEachIssueInItsMappedStage() {
    let result = snapshot([
        issue(key: "DEMO-1", status: "To Do"),
        issue(key: "DEMO-2", status: "In Progress"),
        issue(key: "DEMO-3", status: "In Review"),
    ])

    #expect(result.lanes[0].slots.map(\.issue.key) == ["DEMO-1"])
    #expect(result.lanes[1].slots.map(\.issue.key) == ["DEMO-2"])
    #expect(result.lanes[2].slots.map(\.issue.key) == ["DEMO-3"])
}

/// 완료 상태의 티켓이 미러에 남아 있어도(재할당 직전 등) 레인에는 나타나지 않는다.
@Test func dropsIssuesInTheDoneStage() {
    let result = snapshot([issue(key: "DEMO-1", status: "Done")])

    #expect(result.lanes.allSatisfy(\.slots.isEmpty))
    #expect(result.unmappedIssues.isEmpty)
}

/// 매핑되지 않은 상태의 티켓은 어느 레인에도 들어가지 못한다. 그대로 버리면
/// 보드에서 조용히 사라지고 사용자는 티켓이 없어졌다고 생각한다.
@Test func collectsIssuesWhoseStatusIsNotMapped() {
    let result = snapshot([
        issue(key: "DEMO-9", status: "Blocked"),
        issue(key: "DEMO-1", status: "In Progress"),
    ])

    #expect(result.unmappedIssues.map(\.key) == ["DEMO-9"])
    #expect(result.lanes[1].slots.map(\.issue.key) == ["DEMO-1"])
}

/// 미러는 딕셔너리에서 오므로 입력 순서가 불안정하다. 정렬하지 않으면 매 렌더마다
/// 목록 순서가 뒤바뀐다.
@Test func sortsUnmappedIssuesDeterministically() {
    let result = snapshot([
        issue(key: "DEMO-9", status: "Blocked"),
        issue(key: "DEMO-2", status: "Blocked"),
        issue(key: "DEMO-5", status: "Blocked"),
    ])

    #expect(result.unmappedIssues.map(\.key) == ["DEMO-2", "DEMO-5", "DEMO-9"])
}

@Test func usesStatusEnteredAtForStagnationWhenAvailable() {
    let result = snapshot(
        [issue(key: "DEMO-1", status: "In Progress",
               updated: now.addingTimeInterval(-days(1)))],
        enteredAt: ["DEMO-1": now.addingTimeInterval(-days(30))]
    )

    let slot = result.lanes[1].slots[0]
    #expect(slot.daysStagnant == 30)
    #expect(slot.tier == .raid)
    #expect(slot.isApproximate == false)
}

/// 관측 이력이 없으면 `jiraUpdatedAt`으로 폴백하되 그 사실을 표시한다. 근사값을
/// 확정처럼 보여주면 "관측한 것만 안다"는 이 앱의 원칙이 화면에서 깨진다.
@Test func marksStagnationAsApproximateWithoutHistory() {
    let result = snapshot(
        [issue(key: "DEMO-1", status: "In Progress",
               updated: now.addingTimeInterval(-days(9)))]
    )

    let slot = result.lanes[1].slots[0]
    #expect(slot.daysStagnant == 9)
    #expect(slot.tier == .stale)
    #expect(slot.isApproximate == true)
}

@Test func placesSlotsOnTheAxisByStagnation() {
    let result = snapshot(
        [issue(key: "DEMO-1", status: "In Progress")],
        enteredAt: ["DEMO-1": now.addingTimeInterval(-days(21))]
    )

    #expect(abs(result.lanes[1].slots[0].position - 2.0 / 3) < 0.0001)
}

@Test func reportsNoDueStateWithoutADueDate() {
    let result = snapshot([issue(key: "DEMO-1", status: "In Progress")])

    #expect(result.lanes[1].slots[0].dueState == DueState.none)
}

/// 마감 당일은 아직 지나지 않은 것으로 본다(`DueDate.isOverdue`와 같은 규칙).
@Test func countsTheDueDayItselfAsRemaining() {
    let result = snapshot([issue(key: "DEMO-1", status: "In Progress", due: now)])

    #expect(result.lanes[1].slots[0].dueState == DueState.dueIn(days: 0))
}

@Test func reportsDaysRemainingAndOverdue() {
    let soon = snapshot([
        issue(key: "DEMO-1", status: "In Progress", due: now.addingTimeInterval(days(3)))
    ])
    let late = snapshot([
        issue(key: "DEMO-2", status: "In Progress", due: now.addingTimeInterval(-days(2)))
    ])

    #expect(soon.lanes[1].slots[0].dueState == DueState.dueIn(days: 3))
    #expect(late.lanes[1].slots[0].dueState == DueState.overdue(days: 2))
}

@Test func carriesTheAxisInTheSnapshot() {
    #expect(snapshot([]).axis.map(\.days) == [0, 7, 21, 45])
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter BoardLayout
```

기대: 컴파일 실패 — `cannot find 'BoardLayout' in scope`

- [ ] **Step 3: 최소 구현을 쓴다**

`Packages/Jirarcade/Sources/ArcadeCore/Board/BoardLayout.swift`:

```swift
import Foundation

/// 마감까지 남은 상태. 강조 기준(D-3 이내를 눈에 띄게 할지 등)은 **뷰가 정한다** —
/// `ArcadeCore`는 사실만 담고 표시 정책을 갖지 않는다.
public enum DueState: Sendable, Equatable {
    case none
    case dueIn(days: Int)
    case overdue(days: Int)
}

/// 축 위에 놓인 티켓 하나.
public struct BoardSlot: Sendable, Equatable, Identifiable {
    public var id: String { issue.key }

    public let issue: ObservedIssue
    /// 클램프 전 **실제** 정체일. 축에서는 접혀도 카드는 이 값을 그대로 적는다.
    public let daysStagnant: Int
    public let tier: StagnationTier
    /// 축 위 0.0…1.0 위치.
    public let position: Double
    /// 겹침 해소 결과. 0이 맨 위 줄이다.
    public let row: Int
    /// 관측 이력이 없어 `jiraUpdatedAt`으로 폴백했다.
    public let isApproximate: Bool
    public let dueState: DueState

    public init(
        issue: ObservedIssue, daysStagnant: Int, tier: StagnationTier,
        position: Double, row: Int, isApproximate: Bool, dueState: DueState
    ) {
        self.issue = issue
        self.daysStagnant = daysStagnant
        self.tier = tier
        self.position = position
        self.row = row
        self.isApproximate = isApproximate
        self.dueState = dueState
    }
}

public struct BoardLane: Sendable, Equatable, Identifiable {
    public var id: Stage { stage }

    public let stage: Stage
    public let slots: [BoardSlot]
    /// 뷰가 레인 높이를 정할 때 쓴다. 슬롯이 없으면 0이다.
    public let rowCount: Int

    public init(stage: Stage, slots: [BoardSlot], rowCount: Int) {
        self.stage = stage
        self.slots = slots
        self.rowCount = rowCount
    }
}

public struct BoardSnapshot: Sendable, Equatable {
    public let lanes: [BoardLane]
    /// 어느 레인에도 들어가지 못한 티켓. 화면이 따로 보여줘야 사라지지 않는다.
    public let unmappedIssues: [ObservedIssue]
    public let axis: [AxisTick]

    public init(lanes: [BoardLane], unmappedIssues: [ObservedIssue], axis: [AxisTick]) {
        self.lanes = lanes
        self.unmappedIssues = unmappedIssues
        self.axis = axis
    }
}

/// 미러와 이벤트 로그를 화면에 놓을 좌표로 옮긴다. 순수 함수이며 화면을 모른다.
public enum BoardLayout {
    /// 보드가 그리는 단계. **`done`은 없다** — 동기화 JQL이 `statusCategory != Done`이라
    /// 미러에 완료 티켓이 없고, 영구히 빈 레인은 "뭔가 들어와야 하는데 비어 있다"는
    /// 잘못된 신호다. 전이로 완료한 티켓은 다음 동기화에서 미러에서 사라진다.
    public static let visibleStages: [Stage] = [.backlog, .active, .review, .verify]

    /// - Parameter minimumSpacing: 슬롯이 같은 줄에 놓이기 위한 최소 간격(축 대비 비율).
    ///   `ArcadeCore`는 카드 폭도 화면 폭도 모르므로 뷰가 계산해 넘긴다.
    public static func snapshot(
        issues: [ObservedIssue],
        statusEnteredAt: [String: Date],
        workflow: WorkflowMap,
        rules: RuleSet,
        minimumSpacing: Double,
        now: Date,
        calendar: Calendar
    ) -> BoardSnapshot {
        let classifier = StagnationClassifier(rules: rules)
        var byStage: [Stage: [BoardSlot]] = [:]
        var unmapped: [ObservedIssue] = []

        for issue in issues {
            guard let stage = workflow.stage(for: issue.statusName) else {
                unmapped.append(issue)
                continue
            }
            guard visibleStages.contains(stage) else { continue }

            let entered = statusEnteredAt[issue.key]
            let stagnant = classifier.daysStagnant(
                statusEnteredAt: entered, jiraUpdatedAt: issue.jiraUpdatedAt, now: now
            )
            byStage[stage, default: []].append(BoardSlot(
                issue: issue,
                daysStagnant: stagnant,
                tier: classifier.classify(
                    statusEnteredAt: entered, jiraUpdatedAt: issue.jiraUpdatedAt, now: now
                ),
                position: BoardAxis.position(forDays: stagnant, rules: rules),
                row: 0,
                isApproximate: classifier.isApproximate(statusEnteredAt: entered),
                dueState: dueState(for: issue, now: now, calendar: calendar)
            ))
        }

        let lanes = visibleStages.map { stage in
            let slots = byStage[stage] ?? []
            return BoardLane(stage: stage, slots: slots,
                             rowCount: slots.isEmpty ? 0 : 1)
        }

        // 미매핑 목록도 결정적이어야 한다 — 입력은 미러 딕셔너리 순회에서 오므로 불안정하다.
        return BoardSnapshot(
            lanes: lanes,
            unmappedIssues: unmapped.sorted { $0.key < $1.key },
            axis: BoardAxis.ticks(rules: rules)
        )
    }

    /// 마감 비교는 로컬 달력의 날짜 단위로 한다(v0.1 스펙 §8.6). `DueDate`가 그 규칙을
    /// 이미 갖고 있으므로 여기서 `Date`끼리 비교하지 않는다.
    static func dueState(for issue: ObservedIssue, now: Date, calendar: Calendar) -> DueState {
        guard let due = issue.dueDate else { return .none }
        let remaining = DueDate.daysRemaining(until: due, from: now, calendar: calendar)
        return remaining < 0 ? .overdue(days: -remaining) : .dueIn(days: remaining)
    }
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter BoardLayout
```

기대: 12 tests PASS

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Board/BoardLayout.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/BoardLayoutTests.swift
git commit -m "feat: 티켓을 단계별 레인의 축 위 좌표로 옮기는 BoardLayout

매핑되지 않은 상태의 티켓을 버리지 않고 따로 모은다 — 어느 레인에도 들어가지
못하므로 그대로 두면 보드에서 조용히 사라진다.

done 레인은 그리지 않는다. 동기화 JQL이 statusCategory != Done이라 미러에 완료
티켓이 없고, 영구히 빈 레인은 잘못된 신호다."
```

---

### Task 4: `LanePacker` — 겹침 해소

위치가 가까운 티켓을 수직으로 쌓는다. greedy lane packing이며, 들어갈 수 있는 가장
낮은 줄에 넣는다.

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Board/LanePacker.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Board/BoardLayout.swift` (Task 3의 `lanes` 생성부)
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/LanePackerTests.swift`

**Interfaces:**
- Consumes: `BoardSlot` (Task 3)
- Produces:
  - `LanePacker.pack(_ slots: [BoardSlot], minimumSpacing: Double) -> [BoardSlot]` (internal)
  - `BoardSlot.withRow(_ row: Int) -> BoardSlot` (internal)

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Packages/Jirarcade/Tests/ArcadeCoreTests/LanePackerTests.swift`:

```swift
import Testing
import Foundation
@testable import ArcadeCore

private func slot(_ key: String, at position: Double) -> BoardSlot {
    BoardSlot(
        issue: issue(key: key, status: "In Progress"),
        daysStagnant: 0, tier: .fresh, position: position, row: 0,
        isApproximate: false, dueState: .none
    )
}

private func rows(_ packed: [BoardSlot]) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: packed.map { ($0.issue.key, $0.row) })
}

@Test func keepsDistantSlotsOnTheSameRow() {
    let packed = LanePacker.pack(
        [slot("DEMO-1", at: 0.0), slot("DEMO-2", at: 0.5)], minimumSpacing: 0.1
    )

    #expect(rows(packed) == ["DEMO-1": 0, "DEMO-2": 0])
}

@Test func stacksSlotsThatWouldOverlap() {
    let packed = LanePacker.pack(
        [slot("DEMO-1", at: 0.10), slot("DEMO-2", at: 0.12)], minimumSpacing: 0.1
    )

    #expect(rows(packed) == ["DEMO-1": 0, "DEMO-2": 1])
}

@Test func stacksThreeCrowdedSlotsOnSeparateRows() {
    let packed = LanePacker.pack(
        [slot("DEMO-1", at: 0.10), slot("DEMO-2", at: 0.11), slot("DEMO-3", at: 0.12)],
        minimumSpacing: 0.1
    )

    #expect(rows(packed) == ["DEMO-1": 0, "DEMO-2": 1, "DEMO-3": 2])
}

/// 가장 낮은 줄에 넣는다. 세 번째가 첫 번째에서 충분히 떨어졌으면 새 줄을 만들지 않고
/// 0번 줄로 돌아간다 — 그러지 않으면 레인이 필요 이상으로 높아진다.
@Test func reusesTheLowestRowThatHasSpace() {
    let packed = LanePacker.pack(
        [slot("DEMO-1", at: 0.10), slot("DEMO-2", at: 0.12), slot("DEMO-3", at: 0.40)],
        minimumSpacing: 0.1
    )

    #expect(rows(packed) == ["DEMO-1": 0, "DEMO-2": 1, "DEMO-3": 0])
}

/// Swift의 `sorted(by:)`는 안정 정렬이 아니다. 동률을 issueKey로 가르지 않으면 같은
/// 정체일 티켓 두 건의 상하 순서가 실행마다 뒤집혀 화면이 매 렌더 흔들린다.
@Test func breaksPositionTiesByIssueKey() {
    let packed = LanePacker.pack(
        [slot("DEMO-9", at: 0.3), slot("DEMO-2", at: 0.3), slot("DEMO-5", at: 0.3)],
        minimumSpacing: 0.1
    )

    #expect(rows(packed) == ["DEMO-2": 0, "DEMO-5": 1, "DEMO-9": 2])
}

@Test func returnsSlotsSortedByPosition() {
    let packed = LanePacker.pack(
        [slot("DEMO-3", at: 0.9), slot("DEMO-1", at: 0.1), slot("DEMO-2", at: 0.5)],
        minimumSpacing: 0.1
    )

    #expect(packed.map(\.issue.key) == ["DEMO-1", "DEMO-2", "DEMO-3"])
}

@Test func putsEverythingOnOneRowWhenNoSpacingIsRequired() {
    let packed = LanePacker.pack(
        [slot("DEMO-1", at: 0.1), slot("DEMO-2", at: 0.1)], minimumSpacing: 0
    )

    #expect(rows(packed) == ["DEMO-1": 0, "DEMO-2": 0])
}

@Test func handlesAnEmptyLane() {
    #expect(LanePacker.pack([], minimumSpacing: 0.1).isEmpty)
}
```

그리고 `BoardLayoutTests.swift` 끝에 통합 테스트를 덧붙인다:

```swift
/// 레인이 packing 결과를 담고 rowCount가 실제 줄 수를 말한다.
@Test func laneReportsItsRowCountAfterPacking() {
    let result = snapshot(
        [
            issue(key: "DEMO-1", status: "In Progress"),
            issue(key: "DEMO-2", status: "In Progress"),
        ],
        enteredAt: [
            "DEMO-1": now.addingTimeInterval(-days(10)),
            "DEMO-2": now.addingTimeInterval(-days(10)),
        ],
        spacing: 0.1
    )

    #expect(result.lanes[1].rowCount == 2)
    #expect(result.lanes[1].slots.map(\.row) == [0, 1])
}

@Test func emptyLaneHasNoRows() {
    #expect(snapshot([]).lanes.allSatisfy { $0.rowCount == 0 })
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter "LanePacker|BoardLayout"
```

기대: 컴파일 실패 — `cannot find 'LanePacker' in scope`

- [ ] **Step 3: `LanePacker`를 쓴다**

`Packages/Jirarcade/Sources/ArcadeCore/Board/LanePacker.swift`:

```swift
import Foundation

/// 축 위에서 겹치는 슬롯을 수직으로 쌓는다.
///
/// `public`이 아닌 이유: 이 계산은 `BoardLayout`이 쓰는 부품이고 바깥에서 직접 부를
/// 일이 없다. 테스트는 `@testable import`로 닿는다.
enum LanePacker {
    /// 들어갈 수 있는 **가장 낮은** 줄에 넣는다. 늘 새 줄을 만들면 레인이 필요 이상으로
    /// 높아지고, 늘 마지막 줄만 보면 앞줄의 빈자리가 영영 안 쓰인다.
    ///
    /// - Parameter minimumSpacing: 같은 줄에 놓이기 위한 최소 간격(축 대비 비율).
    ///   0이면 전부 한 줄에 놓인다.
    static func pack(_ slots: [BoardSlot], minimumSpacing: Double) -> [BoardSlot] {
        // 동률 타이브레이크가 필요한 이유: Swift의 `sorted(by:)`는 안정 정렬이 아니므로,
        // 같은 정체일 티켓 두 건의 상하 순서가 실행마다 뒤집힌다. 데이터는 틀어지지
        // 않지만 화면이 매 렌더마다 흔들리고 테스트가 비결정적이 된다.
        let ordered = slots.sorted {
            $0.position == $1.position
                ? $0.issue.key < $1.issue.key
                : $0.position < $1.position
        }

        // rowEnd[i] = i번 줄에 마지막으로 놓인 슬롯의 position.
        // ordered가 오름차순이므로 새 슬롯은 항상 그 값보다 크거나 같다.
        var rowEnd: [Double] = []
        var packed: [BoardSlot] = []
        packed.reserveCapacity(ordered.count)

        for slot in ordered {
            let row = rowEnd.firstIndex { slot.position - $0 >= minimumSpacing } ?? rowEnd.count
            if row == rowEnd.count {
                rowEnd.append(slot.position)
            } else {
                rowEnd[row] = slot.position
            }
            packed.append(slot.withRow(row))
        }
        return packed
    }
}

extension BoardSlot {
    /// `row`만 바꾼 사본. `BoardSlot`이 `let`뿐이므로 packing이 값을 다시 만든다.
    func withRow(_ row: Int) -> BoardSlot {
        BoardSlot(
            issue: issue, daysStagnant: daysStagnant, tier: tier,
            position: position, row: row,
            isApproximate: isApproximate, dueState: dueState
        )
    }
}
```

- [ ] **Step 4: `BoardLayout`이 packer를 쓰게 한다**

`BoardLayout.snapshot`의 `let lanes = ...` 블록을 이렇게 바꾼다:

```swift
        let lanes = visibleStages.map { stage in
            let packed = LanePacker.pack(byStage[stage] ?? [],
                                         minimumSpacing: minimumSpacing)
            // rowCount는 "가장 큰 row + 1"이다. 빈 레인은 -1 + 1 = 0이 되어
            // 뷰가 높이를 0으로 잡는다.
            return BoardLane(stage: stage, slots: packed,
                             rowCount: (packed.map(\.row).max() ?? -1) + 1)
        }
```

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter "LanePacker|BoardLayout"
```

기대: 22 tests PASS (LanePacker 8 + BoardLayout 14)

- [ ] **Step 6: 전체 테스트를 돌린다**

```bash
cd Packages/Jirarcade && swift test
```

기대: 전체 PASS

- [ ] **Step 7: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Board/LanePacker.swift \
        Packages/Jirarcade/Sources/ArcadeCore/Board/BoardLayout.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/LanePackerTests.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/BoardLayoutTests.swift
git commit -m "feat: 축에서 겹치는 슬롯을 수직으로 쌓는 LanePacker

들어갈 수 있는 가장 낮은 줄에 넣는다 — 늘 새 줄을 만들면 레인이 필요 이상으로
높아지고, 마지막 줄만 보면 앞줄의 빈자리가 영영 안 쓰인다.

position 동률은 issueKey로 가른다. Swift의 sorted(by:)는 안정 정렬이 아니라
같은 정체일 티켓의 상하 순서가 실행마다 뒤집힌다."
```

---
### Task 5: `AppModel`이 보드 상태를 노출한다

보드가 필요한 것은 미러·상태 진입 시각·위생 리포트·실효 워크플로 맵이다. 넷 다
`refreshSummaries()`가 이미 읽는 재료에서 나온다 — 그 함수는 `store.loadEvents()`와
`store.loadMirror()`를 둘 다 부르고, 동기화 성공(`AppModel.swift:379`)과 로그인·백필 종료
(`refreshDerivedState()`)가 **공통으로 지나는 유일한 지점**이다.

더 이상 요약만 갱신하지 않으므로 `recomputeFromLog()`로 개명한다. 이름이 하는 일보다
좁으면 다음 사람이 보드 갱신을 여기 두지 않고 새 경로를 만든다.

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/BoardStateTests.swift`

**Interfaces:**
- Consumes: `StatusTimeline.latestStatusEntry(from:)` (Task 1), `HygieneCalculator`, `WorkflowMap`, `JiraSite.normalize(_:)`
- Produces (전부 `AppModel`의 멤버):
  - `var issues: [ObservedIssue]` — 키 오름차순
  - `var statusEnteredAt: [String: Date]`
  - `var hygiene: HygieneReport?`
  - `var boardWorkflow: WorkflowMap`
  - `var siteHost: String?`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Packages/Jirarcade/Tests/ArcadeAppTests/BoardStateTests.swift`:

```swift
import Testing
import Foundation
import ArcadeCore
import JiraKit
@testable import ArcadeApp

private let now = iso("2026-08-21T09:00:00Z")

/// 동기화 한 번을 흉내낸다. `/myself` → 검색 응답 순서로 스크립트한다.
///
/// 워크플로를 미리 심는 이유: 매핑이 없으면 `routeAfterAuthentication()`이 마법사로
/// 보내고 `HygieneCalculator`가 단계를 못 갈라 위생 지표가 전부 0이 된다.
@MainActor
private func modelAfterSync(issuesJSON: String) async throws -> AppModel {
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: demoWorkflow),
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 200, body: Data(issuesJSON.utf8)),
            ])
        },
        now: now
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    await model.syncNow(reason: .manual)
    return model
}

@MainActor
@Test func exposesTheMirrorSortedByKey() async throws {
    let model = try await modelAfterSync(issuesJSON: issuesBody(pairs: [
        (key: "DEMO-9", status: "In Progress", assignee: "acc-me"),
        (key: "DEMO-2", status: "To Do", assignee: "acc-me"),
    ]))

    #expect(model.issues.map(\.key) == ["DEMO-2", "DEMO-9"])
}

@MainActor
@Test func exposesTheEffectiveWorkflowMap() async throws {
    let model = try makeModel(workflow: InMemoryWorkflowStore(seeded: demoWorkflow),
                              now: now)

    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")

    #expect(model.boardWorkflow.stage(for: "In Progress") == .active)
}

@MainActor
@Test func exposesTheHygieneReport() async throws {
    let model = try await modelAfterSync(issuesJSON: issuesBody(
        status: "In Progress", assignee: "acc-me"
    ))

    #expect(model.hygiene != nil)
    #expect(model.hygiene?.wipCount == 1)
}

/// Jira 링크를 만들려면 호스트가 필요하다. 자격증명 전체가 아니라 호스트 문자열
/// 하나만 노출한다 — 이메일과 토큰은 화면에 닿을 이유가 없다.
@MainActor
@Test func exposesTheNormalizedSiteHost() async throws {
    let model = try makeModel(now: now)

    await model.signIn(site: "HTTPS://Example.Atlassian.Net/",
                           email: "t@example.com", token: "tok")

    #expect(model.siteHost == "example.atlassian.net")
}

@MainActor
@Test func clearsBoardStateOnSignOut() async throws {
    let model = try await modelAfterSync(issuesJSON: issuesBody(
        status: "In Progress", assignee: "acc-me"
    ))
    #expect(!model.issues.isEmpty)

    await model.signOut()

    #expect(model.issues.isEmpty)
    #expect(model.statusEnteredAt.isEmpty)
    #expect(model.hygiene == nil)
    #expect(model.siteHost == nil)
}
```

> **주의:** 검색 응답 픽스처는 `TestSupport.swift`의 `issuesBody(pairs:)`와
> `issuesBody(status:assignee:)`다. 이 헬퍼는 `updated`를
> `2026-08-14T09:00:00.000+0000`으로 **고정**하고 `duedate`를 넣지 않는다 —
> 정체일이나 마감을 흔들어야 하는 테스트는 HTTP를 거치지 말고
> `seedIssuesForTesting`(Task 6에서 추가)을 쓴다. 기존 헬퍼를 고치지 말 것.
> `AppModel.signIn(site:email:token:)`은 `async`이며 **throws가 아니다**.

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter BoardState
```

기대: 컴파일 실패 — `value of type 'AppModel' has no member 'issues'`

- [ ] **Step 3: 프로퍼티를 더한다**

`AppModel`의 `myAccountId` 선언 바로 아래에 넣는다:

```swift
    /// 현재 미러를 키 오름차순으로. 보드가 읽는다.
    ///
    /// 정렬을 여기서 하는 이유: 미러는 딕셔너리라 순회 순서가 불안정하고, 보드가 매
    /// 렌더마다 정렬하면 같은 일을 반복한다. 갱신은 동기화마다 한 번뿐이다.
    public private(set) var issues: [ObservedIssue] = []
    /// 티켓별 현재 상태 진입 시각. 없는 티켓은 보드가 `jiraUpdatedAt`으로 폴백하고
    /// 그 사실을 화면에 표시한다.
    public private(set) var statusEnteredAt: [String: Date] = [:]
    /// 위생 리포트. HUD가 읽는다.
    public private(set) var hygiene: HygieneReport?
    /// 실효 워크플로 맵(사용자 매핑 + 폴백)의 **캐시**.
    ///
    /// `currentMapping`/`currentFallbacks`처럼 매 접근마다 디스크를 치면 안 된다 —
    /// 보드는 렌더마다 이 값을 읽고 티켓 수만큼 `stage(for:)`를 부른다.
    public private(set) var boardWorkflow = WorkflowMap(statusToStage: [:])
    /// 정규화된 Jira 호스트. 티켓 링크를 만들 때만 쓴다.
    /// 자격증명 전체가 아니라 호스트 하나만 내보낸다 — 이메일과 토큰은 화면에 닿을 이유가 없다.
    public private(set) var siteHost: String?
```

- [ ] **Step 4: `refreshSummaries()`를 `recomputeFromLog()`로 개명하고 보드 상태를 채운다**

`AppModel.swift`의 `refreshSummaries()` 전체를 이것으로 교체한다:

```swift
    /// 이벤트 로그와 미러에서 파생되는 모든 것을 다시 만든다 — 보드가 읽는 상태와
    /// 통산·시즌 요약.
    ///
    /// 동기화 성공과 로그인·백필 종료가 **공통으로 지나는 유일한 지점**이고, 이미
    /// 이벤트 로그와 미러를 둘 다 읽고 있다. 보드 갱신을 위해 새 갱신 시점이나 새
    /// 스토어 읽기를 만들 이유가 없다.
    private func recomputeFromLog() async {
        guard let events = try? store.loadEvents(),
              let mirror = try? store.loadMirror() else { return }
        let now = clock()
        // 한 번만 읽어 캐시한다. 예전에는 이 함수 안에서만 두 번 불렀고 화면이 렌더마다
        // 또 불렀다(후속 항목 §4.2).
        let workflowMap = effectiveWorkflow()
        boardWorkflow = workflowMap

        issues = mirror.values.sorted { $0.key < $1.key }
        statusEnteredAt = StatusTimeline.latestStatusEntry(from: events)
        hygiene = HygieneCalculator(rules: rules, workflow: workflowMap, calendar: calendar)
            .evaluate(issues, now: now)

        let engine = ScoreEngine(
            rules: rules, workflow: workflowMap,
            calendar: calendar, myAccountId: myAccountId
        )
        lifetimeSummary = engine.recompute(events: events, issues: mirror, now: now).summary
        let seasonStart = now.addingTimeInterval(-Double(rules.seasonDays) * 86_400)
        seasonSummary = engine.recompute(events: events, issues: mirror, now: now,
                                         since: seasonStart).summary
    }
```

호출부 두 곳을 바꾼다:
- `refreshDerivedState()` 끝의 `await refreshSummaries()` → `await recomputeFromLog()`
- `performSync()` 끝의 `await refreshSummaries()` → `await recomputeFromLog()`

```bash
# 남은 호출이 없는지 확인
rg 'refreshSummaries' Packages/Jirarcade/
```

기대: 0건

- [ ] **Step 5: `siteHost`를 채우고 지운다**

`validate(_:persistOnSuccess:)`에서 `myAccountId = me.accountId` **바로 아래**에 넣는다:

```swift
        // 티켓 링크를 만들 때 쓴다. APITokenAuth와 같은 정규화를 거쳐야 사용자가 어떻게
        // 입력했든 같은 호스트가 된다.
        siteHost = JiraSite.normalize(creds.site)
```

`signOut()`에서 `myAccountId = nil` **바로 아래**에 넣는다:

```swift
        siteHost = nil
        // 보드 상태도 이 계정의 미러에서 나온 값이다. 남겨두면 다음 로그인이 끝나기
        // 전까지 남의 티켓이 화면에 떠 있다.
        issues = []
        statusEnteredAt = [:]
        hygiene = nil
        boardWorkflow = WorkflowMap(statusToStage: [:])
```

- [ ] **Step 6: 테스트가 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter BoardState
```

기대: 5 tests PASS

- [ ] **Step 7: 전체 테스트를 돌린다**

```bash
cd Packages/Jirarcade && swift test
```

기대: 전체 PASS. `AppModelTests`가 `refreshSummaries`를 이름으로 참조하고 있으면 함께 고친다.

- [ ] **Step 8: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift \
        Packages/Jirarcade/Tests/ArcadeAppTests/BoardStateTests.swift
git commit -m "feat: AppModel이 보드 상태를 노출한다

미러·상태 진입 시각·위생 리포트·실효 워크플로 맵을 refreshSummaries()에서 함께
갱신한다. 그 함수가 동기화 성공과 로그인·백필 종료가 공통으로 지나는 유일한
지점이고 이미 이벤트 로그와 미러를 둘 다 읽는다.

더 이상 요약만 갱신하지 않으므로 recomputeFromLog()로 개명한다. 실효 워크플로
맵은 한 번 읽어 캐시한다 — 보드는 렌더마다 티켓 수만큼 stage(for:)를 부른다."
```

---

### Task 6: 전이 대기 — 5초 실행 취소

요청은 5초 뒤에 나간다. 그 안에 취소하면 Jira에 흔적이 남지 않는다(v0.1 스펙 §8.5).
대기는 **티켓 키로 색인된 딕셔너리**이며 각 항목이 자기 타이머를 갖는다 — 하나만
대기하게 하면 세 티켓을 연달아 정리할 때 앞의 두 건이 취소 기회를 잃는다.

이 태스크는 대기·취소·교체까지만 한다. 실제 요청 실행은 Task 7이다.

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeApp/PendingTransition.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeApp/AppSettings.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/TransitionTests.swift`

**Interfaces:**
- Consumes: `JiraTransition` (`JiraKit/DTO.swift` — `id`, `name`, `toStatusName`), `AppModel.issues` (Task 5)
- Produces:
  - `struct PendingTransition { issueKey, transitionId, toStatusName, fromStatusName, firesAt }`
  - `AppSettings.transitionUndoWindow: Duration`
  - `AppModel.pendingTransitions: [String: PendingTransition]`
  - `AppModel.requestTransition(issueKey:transition:)`
  - `AppModel.cancelPendingTransition(issueKey:)`
  - `AppModel.init(..., transitionSleep:)` — 테스트가 대기를 제어한다

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Packages/Jirarcade/Tests/ArcadeAppTests/TransitionTests.swift`:

```swift
import Testing
import Foundation
import ArcadeCore
import JiraKit
@testable import ArcadeApp

private let now = iso("2026-08-21T09:00:00Z")

/// 깨어날 시점을 테스트가 직접 정하는 sleep. `SyncScheduler`가 sleep을 주입받는 것과
/// 같은 패턴이다 — 실제로 5초를 기다리면 테스트가 5초씩 늘어나고, 밀리초로 줄이면
/// 취소 테스트가 타이밍에 따라 흔들린다.
actor ManualSleep {
    private var resume: (@Sendable () -> Void)?
    private var pending = 0

    func sleep(_ duration: Duration) async throws {
        pending += 1
        await withCheckedContinuation { continuation in
            resume = { continuation.resume() }
        }
        try Task.checkCancellation()
    }

    /// 대기 중인 sleep을 깨운다.
    func fire() {
        let block = resume
        resume = nil
        block?()
    }

    var hasSleeper: Bool { resume != nil }
}

/// `JiraTransition`은 memberwise init이 없고 `Decodable`로만 만들어진다.
/// `decodeList`가 throws라 전역 `let`에서는 부를 수 없으므로 헬퍼로 감싼다.
private func transition(
    id: String, name: String, to status: String
) throws -> JiraTransition {
    let body = """
    {"transitions":[{"id":"\(id)","name":"\(name)","to":{"name":"\(status)"}}]}
    """
    return try #require(JiraTransition.decodeList(Data(body.utf8)).first)
}

@MainActor
@Test func holdsTheRequestDuringTheUndoWindow() async throws {
    let sleeper = ManualSleep()
    let model = try makeModel(
        http: { ScriptedHTTP([.init(status: 200, body: Data(myselfBody.utf8))]) },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))

    #expect(model.pendingTransitions["DEMO-1"]?.toStatusName == "Done")
    #expect(model.pendingTransitions["DEMO-1"]?.fromStatusName == "In Progress")
}

/// 취소하면 요청이 나가지 않는다. HTTP 스텁에 응답을 하나(`/myself`)만 넣어 뒀으므로,
/// 전이 요청이 나갔다면 `badServerResponse`로 실패해 흔적이 남는다.
@MainActor
@Test func cancellingBeforeTheWindowElapsesSendsNothing() async throws {
    let sleeper = ManualSleep()
    let model = try makeModel(
        http: { ScriptedHTTP([.init(status: 200, body: Data(myselfBody.utf8))]) },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])
    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))

    model.cancelPendingTransition(issueKey: "DEMO-1")

    #expect(model.pendingTransitions["DEMO-1"] == nil)
    #expect(model.transitionFailures["DEMO-1"] == nil)
}

/// 잘못 골랐을 때 취소하고 다시 고르는 것과 결과가 같아야 한다.
@MainActor
@Test func requestingAgainForTheSameIssueReplacesTheWaitingOne() async throws {
    let sleeper = ManualSleep()
    let model = try makeModel(
        http: { ScriptedHTTP([.init(status: 200, body: Data(myselfBody.utf8))]) },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))
    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "21", name: "리뷰로", to: "In Review"))

    #expect(model.pendingTransitions.count == 1)
    #expect(model.pendingTransitions["DEMO-1"]?.transitionId == "21")
    #expect(model.pendingTransitions["DEMO-1"]?.toStatusName == "In Review")
}

/// 두 티켓을 연달아 옮겨도 각자 자기 창을 갖는다. 하나만 대기하게 하면 앞의 것이
/// 즉시 확정되어 취소 기회를 잃는다.
@MainActor
@Test func eachIssueGetsItsOwnUndoWindow() async throws {
    let sleeper = ManualSleep()
    let model = try makeModel(
        http: { ScriptedHTTP([.init(status: 200, body: Data(myselfBody.utf8))]) },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([
        issue(key: "DEMO-1", status: "In Progress"),
        issue(key: "DEMO-2", status: "In Progress"),
    ])

    model.requestTransition(issueKey: "DEMO-1", transition: try transition(id: "31", name: "완료로", to: "Done"))
    model.requestTransition(issueKey: "DEMO-2", transition: try transition(id: "31", name: "완료로", to: "Done"))

    #expect(model.pendingTransitions.count == 2)
}

/// 미러에 없는 티켓은 되돌릴 기준 상태를 알 수 없으므로 요청 자체를 받지 않는다.
@MainActor
@Test func ignoresATransitionForAnUnknownIssue() async throws {
    let model = try makeModel(now: now)
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")

    model.requestTransition(issueKey: "DEMO-404",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))

    #expect(model.pendingTransitions.isEmpty)
}
```

`Tests/ArcadeAppTests/TestSupport.swift`의 `makeModel`에 파라미터를 더한다:

```swift
    transitionSleep: (@Sendable (Duration) async throws -> Void)? = nil,
```

그리고 `AppModel(...)` 생성 인자에 다음 줄을 더한다:

```swift
        transitionSleep: transitionSleep ?? { try await Task.sleep(for: $0) },
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter Transition
```

기대: 컴파일 실패 — `no member 'pendingTransitions'`

- [ ] **Step 3: `PendingTransition`을 만든다**

`Packages/Jirarcade/Sources/ArcadeApp/PendingTransition.swift`:

```swift
import Foundation

/// 실행 취소 창 안에서 대기 중인 전이 한 건.
///
/// 값 타입이며 스토어에 쓰지 않는다. 롤백은 이 값을 지우는 것이고, Jira에는 아직
/// 아무것도 보내지 않았으므로 되돌릴 것도 없다.
public struct PendingTransition: Sendable, Equatable {
    public let issueKey: String
    public let transitionId: String
    /// 낙관적으로 그릴 상태명. 보드가 이 값으로 단계를 다시 가른다.
    public let toStatusName: String
    /// 되돌릴 때 쓸 원래 상태명.
    ///
    /// **요청 시점에 붙잡아 둔다.** 실행 시점에 미러를 다시 읽으면 그 사이 동기화가
    /// 미러를 갱신했을 수 있고, 그러면 롤백이 엉뚱한 상태로 되돌린다.
    public let fromStatusName: String
    /// 요청이 나갈 시각. 카드가 남은 시간을 그린다.
    public let firesAt: Date

    public init(
        issueKey: String, transitionId: String, toStatusName: String,
        fromStatusName: String, firesAt: Date
    ) {
        self.issueKey = issueKey
        self.transitionId = transitionId
        self.toStatusName = toStatusName
        self.fromStatusName = fromStatusName
        self.firesAt = firesAt
    }
}
```

- [ ] **Step 4: `AppSettings`에 창 길이를 더한다**

`AppSettings`의 `failuresBeforeSurfacing` 아래에 프로퍼티를 더하고, `init`과 `default`에도 반영한다:

```swift
    /// 전이 요청을 보내기 전에 기다리는 시간. 이 창 안에서 취소하면 Jira에 흔적이 없다.
    ///
    /// `RuleSet`이 아니라 여기 두는 이유: 이 값은 점수에 영향을 주지 않는다.
    /// 사용자가 규칙을 재집계해도 바뀌지 않아야 한다.
    public var transitionUndoWindow: Duration
```

```swift
    public static let `default` = AppSettings(
        syncInterval: .seconds(300),
        foregroundCooldown: .seconds(30),
        backoffSteps: [.seconds(5), .seconds(30), .seconds(120), .seconds(600)],
        failuresBeforeSurfacing: 3,
        transitionUndoWindow: .seconds(5)
    )
```

- [ ] **Step 5: `AppModel`에 대기와 취소를 더한다**

프로퍼티 (Task 5에서 더한 `siteHost` 아래):

```swift
    /// 실행 취소 창에서 대기 중인 전이. 티켓 키로 색인한다.
    ///
    /// 하나만 대기하게 하면 "새 전이가 오면 앞의 것을 즉시 확정한다"는 규칙이 따라붙고,
    /// 그러면 세 티켓을 연달아 정리하는 흐름에서 앞의 두 건이 취소 기회를 잃는다.
    /// 5초 실행 취소가 "다른 티켓을 건드리지 않는 한"이라는 숨은 조건을 갖게 된다.
    public private(set) var pendingTransitions: [String: PendingTransition] = [:]
    /// 티켓별 마지막 전이 실패 안내. **Jira가 준 사유를 담지 않는다** — 앱이 쓴 문구만 담는다.
    public private(set) var transitionFailures: [String: String] = [:]

    /// 대기 중인 타이머. 취소하려면 이걸 취소한다.
    private var transitionTasks: [String: Task<Void, Never>] = [:]
    private let transitionSleep: @Sendable (Duration) async throws -> Void
```

`init`에 파라미터를 더한다 (기본값이 있으므로 기존 호출부는 그대로 컴파일된다):

```swift
        transitionSleep: @Sendable @escaping (Duration) async throws -> Void
            = { try await Task.sleep(for: $0) },
```

그리고 본문에 `self.transitionSleep = transitionSleep`을 더한다.

메서드:

```swift
    /// 이 티켓에서 지금 고를 수 있는 전이. **캐싱하지 않는다** — 관리자가 워크플로를
    /// 바꾸면 캐시된 전이 ID는 즉시 틀린 값이 된다(v0.1 스펙 §8.5).
    public func availableTransitions(for issueKey: String) async throws -> [JiraTransition] {
        guard let client else { throw JiraError.unauthorized }
        return try await client.transitions(issueKey: issueKey)
    }

    /// 전이를 예약한다. 요청은 실행 취소 창이 지난 뒤에 나간다.
    public func requestTransition(issueKey: String, transition: JiraTransition) {
        // 미러에 없으면 되돌릴 기준 상태를 알 수 없다. 화면에 없는 티켓이므로 사용자가
        // 고를 수 있는 상황도 아니다 — 조용히 무시한다.
        guard let current = issues.first(where: { $0.key == issueKey }) else { return }

        // 같은 티켓의 대기를 교체한다. 취소하고 다시 고르는 것과 결과가 같아야 한다.
        transitionTasks[issueKey]?.cancel()
        transitionFailures[issueKey] = nil

        let window = settings.transitionUndoWindow
        pendingTransitions[issueKey] = PendingTransition(
            issueKey: issueKey,
            transitionId: transition.id,
            toStatusName: transition.toStatusName,
            fromStatusName: current.statusName,
            firesAt: clock().addingTimeInterval(Double(window.components.seconds))
        )
        transitionTasks[issueKey] = Task { [weak self, transitionSleep] in
            do {
                try await transitionSleep(window)
            } catch {
                // 취소됐다 — 요청을 보내지 않는다. 그것이 이 창의 전부다.
                return
            }
            guard !Task.isCancelled else { return }
            await self?.executeTransition(issueKey: issueKey)
        }
    }

    /// 대기 중인 전이를 되돌린다. Jira에는 아직 아무것도 보내지 않았다.
    public func cancelPendingTransition(issueKey: String) {
        transitionTasks[issueKey]?.cancel()
        transitionTasks[issueKey] = nil
        pendingTransitions[issueKey] = nil
    }

    public func dismissTransitionFailure(issueKey: String) {
        transitionFailures[issueKey] = nil
    }

    /// Task 7에서 채운다. 지금은 대기만 지운다.
    private func executeTransition(issueKey: String) async {
        pendingTransitions[issueKey] = nil
        transitionTasks[issueKey] = nil
    }
```

- [ ] **Step 6: 테스트용 미러 주입을 더한다**

`AppModel` 끝에 넣는다:

```swift
    /// 테스트가 동기화 없이 보드 상태를 준비하기 위한 통로.
    ///
    /// 프로덕션 경로는 `recomputeFromLog()`뿐이다. 이 함수를 프로덕션 코드에서 부르면
    /// 미러와 화면이 갈라진다.
    func seedIssuesForTesting(_ seeded: [ObservedIssue]) {
        issues = seeded.sorted { $0.key < $1.key }
    }
```

`internal`이므로 `@testable import ArcadeApp`에서만 보인다.

- [ ] **Step 7: 테스트가 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter Transition
```

기대: 5 tests PASS

- [ ] **Step 8: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeApp/PendingTransition.swift \
        Packages/Jirarcade/Sources/ArcadeApp/AppSettings.swift \
        Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift \
        Packages/Jirarcade/Tests/ArcadeAppTests/TransitionTests.swift \
        Packages/Jirarcade/Tests/ArcadeAppTests/TestSupport.swift
git commit -m "feat: 전이 5초 실행 취소 — 티켓마다 독립된 타이머

요청은 창이 지난 뒤에 나간다. 그 안에 취소하면 Jira에 흔적이 남지 않는다 —
요청 후 되돌리면 팀원의 알림에 왕복 기록이 남는다(v0.1 스펙 §8.5).

대기를 티켓 키로 색인한다. 하나만 대기하게 하면 세 티켓을 연달아 정리할 때
앞의 두 건이 취소 기회를 잃는다.

되돌릴 기준 상태는 요청 시점에 붙잡는다. 실행 시점에 미러를 다시 읽으면 그
사이 동기화가 미러를 갱신했을 수 있다."
```

---
### Task 7: 전이 실행 — 성공하면 동기화, 실패하면 롤백

창이 지나면 요청을 보낸다. **성공해도 XP를 직접 주지 않는다** — 동기화를 트리거해
diff가 이벤트를 만들고 `ScoreEngine`이 여느 이벤트와 똑같이 채점하게 한다. 그래야
"점수는 관측 로그의 순수 함수"라는 불변식이 유지되고, 재집계 결과가 달라지지 않는다.

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift` (`executeTransition`)
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/TransitionTests.swift` (덧붙임)

**Interfaces:**
- Consumes: `JiraClient.performTransition(issueKey:transitionId:)`, `AppModel.syncNow(reason:)`, `PendingTransition` (Task 6)
- Produces: `AppModel.transitionFailures[issueKey]`가 채워지는 조건 — 401은 `phase = .expired`로 가고 실패 목록에 남지 않는다

- [ ] **Step 1: 실패하는 테스트를 덧붙인다**

`TransitionTests.swift` 끝에 추가한다:

```swift
/// 창이 지나면 요청이 나가고, 성공하면 동기화가 뒤따른다. XP를 직접 주지 않고
/// diff가 이벤트를 만들게 하는 것이 이 앱의 채점 불변식을 지키는 방법이다.
@MainActor
@Test func firingTheTransitionSyncsAfterSuccess() async throws {
    let sleeper = ManualSleep()
    let model = try makeModel(
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),   // /myself
                .init(status: 204, body: Data()),                  // POST transitions
                .init(status: 200, body: Data(issuesBody(pairs: []).utf8)), // 뒤따르는 동기화
            ])
        },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])
    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))

    await sleeper.fire()
    await Task.yield()

    #expect(model.pendingTransitions["DEMO-1"] == nil)
    #expect(model.transitionFailures["DEMO-1"] == nil)
    #expect(model.lastSync != nil)
}

/// 400은 대부분 "필수 필드가 비어 있다"이다. 사유는 Jira 응답 본문에서 오고 그 안에
/// 이메일이 섞일 수 있으므로 화면에 옮기지 않는다 — 대신 Jira로 가는 길을 준다.
@MainActor
@Test func aRejectedTransitionRollsBackWithoutQuotingJira() async throws {
    let sleeper = ManualSleep()
    let leak = "someone@example.com"
    let model = try makeModel(
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 400,
                      body: Data(#"{"errorMessages":["\#(leak) 필드가 필요합니다"]}"#.utf8)),
            ])
        },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])
    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))

    await sleeper.fire()
    await Task.yield()

    #expect(model.pendingTransitions["DEMO-1"] == nil)
    let message = try #require(model.transitionFailures["DEMO-1"])
    #expect(!message.contains(leak), "Jira 응답 본문이 화면 문구에 섞였다: \(message)")
    #expect(!message.contains("@"))
}

@MainActor
@Test func anExpiredTokenDuringTransitionGoesToTheExpiredPhase() async throws {
    let sleeper = ManualSleep()
    let model = try makeModel(
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 401, body: Data()),
            ])
        },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])
    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))

    await sleeper.fire()
    await Task.yield()

    #expect(model.phase == .expired)
    #expect(model.pendingTransitions["DEMO-1"] == nil)
    // 만료 배너가 이미 같은 사실을 말한다. 카드에도 실패를 띄우면 인증 문제가 두 번 보인다.
    #expect(model.transitionFailures["DEMO-1"] == nil)
}

@MainActor
@Test func dismissingClearsTheFailure() async throws {
    let sleeper = ManualSleep()
    let model = try makeModel(
        http: {
            ScriptedHTTP([
                .init(status: 200, body: Data(myselfBody.utf8)),
                .init(status: 500, body: Data()),
            ])
        },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])
    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "31", name: "완료로", to: "Done"))
    await sleeper.fire()
    await Task.yield()
    #expect(model.transitionFailures["DEMO-1"] != nil)

    model.dismissTransitionFailure(issueKey: "DEMO-1")

    #expect(model.transitionFailures["DEMO-1"] == nil)
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter Transition
```

기대: 새 테스트 4개 FAIL (`executeTransition`이 아직 대기만 지운다)

- [ ] **Step 3: `executeTransition`을 채운다**

Task 6에서 자리만 만들어 둔 `executeTransition`을 이것으로 교체한다:

```swift
    /// 실행 취소 창이 지난 뒤 실제로 요청을 보낸다.
    private func executeTransition(issueKey: String) async {
        guard let pending = pendingTransitions[issueKey], let client else {
            pendingTransitions[issueKey] = nil
            transitionTasks[issueKey] = nil
            return
        }
        // 결과와 무관하게 대기는 끝난다. 낙관적 표시를 남겨두면 실패했는데도 카드가
        // 새 레인에 머문다.
        pendingTransitions[issueKey] = nil
        transitionTasks[issueKey] = nil

        do {
            try await client.performTransition(issueKey: issueKey,
                                               transitionId: pending.transitionId)
        } catch JiraError.unauthorized {
            // 만료 배너가 이미 같은 사실을 말한다. 카드에도 실패를 띄우면 인증 문제가
            // 두 번 보이고, 사용자는 티켓 문제와 세션 문제를 구분하지 못한다.
            phase = .expired
            return
        } catch {
            transitionFailures[issueKey] = Self.transitionFailureMessage(error)
            return
        }

        // XP를 직접 주지 않는다. 동기화가 diff로 `.statusChanged`를 만들고 ScoreEngine이
        // 여느 이벤트와 똑같이 채점한다 — 점수가 관측 로그의 순수 함수라는 불변식을
        // 지키는 유일한 방법이고, 덕분에 AbuseGuard의 왕복 차단도 그대로 적용된다.
        await syncNow(reason: .manual)
    }

    /// 화면에 띄울 실패 안내. **Jira가 준 사유를 옮기지 않는다.**
    ///
    /// `JiraError.transitionRejected(reason:)`는 Jira 응답의 `errorMessages`를 그대로
    /// 담고 그 본문에는 이메일이 섞일 수 있다(`redactedErrorDescription` 참고).
    /// v0.1 스펙 §8.4는 화면에 닿는 실패 문자열까지 이 제약 아래 둔다.
    ///
    /// 사유 대신 Jira로 가는 길을 준다 — 전이가 거부되는 이유는 앱이 채울 수 없는
    /// 정보를 Jira가 요구하기 때문이고, 그것을 채울 수 있는 곳은 어차피 Jira다.
    private static func transitionFailureMessage(_ error: any Error) -> String {
        switch error {
        case JiraError.transitionRejected:
            return "Jira가 이 전이를 거부했습니다. 필요한 정보를 Jira에서 채워 주세요."
        case JiraError.offline:
            return "연결되지 않았습니다. 다시 시도해 주세요."
        case JiraError.forbidden:
            return "이 티켓을 옮길 권한이 없습니다."
        case JiraError.notFound:
            return "티켓을 찾을 수 없습니다. Jira에서 삭제되었을 수 있습니다."
        case JiraError.rateLimited:
            return "요청이 너무 잦습니다. 잠시 뒤 다시 시도해 주세요."
        default:
            return "전이하지 못했습니다. 잠시 뒤 다시 시도해 주세요."
        }
    }
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter Transition
```

기대: 9 tests PASS

- [ ] **Step 5: 전체 테스트를 돌린다**

```bash
cd Packages/Jirarcade && swift test
```

기대: 전체 PASS

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift \
        Packages/Jirarcade/Tests/ArcadeAppTests/TransitionTests.swift
git commit -m "feat: 전이 실행 — 성공하면 동기화, 실패하면 롤백

성공해도 XP를 직접 주지 않는다. 동기화를 트리거해 diff가 이벤트를 만들고
ScoreEngine이 여느 이벤트처럼 채점하게 한다 — 점수가 관측 로그의 순수 함수라는
불변식을 지키는 유일한 방법이고, AbuseGuard의 왕복 차단도 그대로 적용된다.

Jira가 준 거부 사유를 화면에 옮기지 않는다. transitionRejected(reason:)는 응답
본문을 담고 그 안에 이메일이 섞일 수 있다. 회귀 테스트가 이메일이 문구에
새지 않는지 확인한다."
```

---

### Task 8: `Cabinet.presentation`과 전체 화면 전환

퀘스트 보드는 매일 여러 번 여는 화면이다. 지금 캐비닛은 `minWidth: 420` 시트로 열리는데
(`ArcadeFloorView.swift`), 시트는 잠깐 들여다보고 닫는 것이라 맞지 않는다.

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/Cabinet.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/ArcadeFloorView.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/AtlassianLinks.swift`
- Create: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/QuestBoardCabinet.swift`
- Create: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/QuestBoardView.swift` (골격만)
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/ModuleBoundaryTests.swift` (덧붙임)

**Interfaces:**
- Consumes: `AppModel.issues`, `AppModel.siteHost` (Task 5)
- Produces:
  - `enum CabinetPresentation { case sheet, fullScreen }`
  - `Cabinet.presentation` (기본 구현 `.sheet`)
  - `AtlassianLinks.issue(key: String, site: String) -> URL?`
  - `QuestBoardCabinet`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`ArcadeUI`에는 테스트 타깃이 없으므로 `ModuleBoundaryTests.swift`의 소스 텍스트 검사에
덧붙인다. 기존 `theExpiredBannerLinksToTokenReissue`와 같은 방식이다.

```swift
/// 보드는 시트가 아니라 전체 화면으로 열려야 한다. 매일 여러 번 여는 화면이고
/// 시트(minWidth 420)로는 레인 네 개와 축이 들어가지 않는다.
@Test func theQuestBoardOpensFullScreen() throws {
    let file = sourcesDirectory()
        .appendingPathComponent("ArcadeUI")
        .appendingPathComponent("QuestBoard")
        .appendingPathComponent("QuestBoardCabinet.swift")
    let text = try String(contentsOf: file, encoding: .utf8)

    #expect(text.contains("var presentation: CabinetPresentation { .fullScreen }"),
            "퀘스트 보드가 전체 화면으로 열리지 않는다")
}

/// 티켓 URL도 토큰 페이지와 같은 규칙을 받는다 — 한곳에서만 만든다.
/// 카드와 실패 안내가 각자 문자열을 조립하면 한쪽만 고쳤을 때 다른 곳이 깨진다.
@Test func theIssueURLIsBuiltInExactlyOnePlace() throws {
    let files = swiftFiles(in: sourcesDirectory())
    #expect(!files.isEmpty)

    let needle = "/browse/"
    var holders: [String] = []
    for file in files where try String(contentsOf: file, encoding: .utf8).contains(needle) {
        holders.append(file.lastPathComponent)
    }

    #expect(holders == ["AtlassianLinks.swift"],
            "티켓 URL이 여러 곳에서 조립된다: \(holders.sorted())")
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter "QuestBoard|IssueURL"
```

기대: FAIL — `QuestBoardCabinet.swift`가 없다

- [ ] **Step 3: `Cabinet`에 표시 방식을 더한다**

`Sources/ArcadeUI/Cabinet.swift`:

```swift
/// 캐비닛을 어떻게 띄우는가.
///
/// 시트는 잠깐 들여다보고 닫는 것이다. 매일 여러 번 여는 화면(퀘스트 보드)에는
/// 맞지 않으므로 같은 창을 채우는 전환을 따로 둔다.
public enum CabinetPresentation: Sendable {
    case sheet
    case fullScreen
}
```

`Cabinet` 프로토콜에 요구사항을 더하고, 기본 구현을 둬서 `ObservationCabinet`을 건드리지
않는다:

```swift
@MainActor
public protocol Cabinet: Identifiable {
    // ...기존 요구사항 그대로...
    var presentation: CabinetPresentation { get }
}

public extension Cabinet {
    /// 기본은 시트다. 전체 화면이 필요한 캐비닛만 스스로 밝힌다.
    var presentation: CabinetPresentation { .sheet }
}
```

- [ ] **Step 4: `AtlassianLinks`에 티켓 URL을 더한다**

`Sources/ArcadeUI/AtlassianLinks.swift`의 `apiTokens` 아래에 추가한다:

```swift
    /// 티켓 하나의 Jira 페이지.
    ///
    /// 이 앱이 하지 않는 일(본문 읽기·첨부·이력)이 아직 많고 전부 그쪽에 있다.
    /// 전이가 거부됐을 때도 필요한 정보를 채우러 갈 곳이 여기다.
    ///
    /// `site`는 `JiraSite.normalize`를 거친 호스트여야 한다 — 스킴이 붙어 있으면
    /// `https://https://…`가 된다.
    static func issue(key: String, site: String) -> URL? {
        guard !site.isEmpty, !key.isEmpty else { return nil }
        return URL(string: "https://\(site)/browse/\(key)")
    }
```

- [ ] **Step 5: 캐비닛과 뷰 골격을 만든다**

`Sources/ArcadeUI/QuestBoard/QuestBoardCabinet.swift`:

```swift
import SwiftUI
import ArcadeApp

/// 내 티켓을 정체 시간축 위에 늘어놓는 캐비닛. 이 앱의 본체다.
@MainActor
struct QuestBoardCabinet: Cabinet {
    let model: AppModel

    nonisolated var id: String { "quest-board" }
    var title: String { "QUEST BOARD" }
    var accentToken: String { "accent" }
    var presentation: CabinetPresentation { .fullScreen }

    var marqueeLines: [String] {
        guard !model.issues.isEmpty else {
            return [model.lastSync == nil ? "아직 동기화 전" : "담당한 미완료 티켓 없음"]
        }
        var lines = ["내 티켓 \(model.issues.count)건"]
        if let hygiene = model.hygiene {
            lines.append("위생 \(hygiene.score)")
        }
        return lines
    }

    func makeView() -> AnyView {
        AnyView(QuestBoardView(model: model))
    }
}
```

`Sources/ArcadeUI/QuestBoard/QuestBoardView.swift` (Task 9에서 채운다):

```swift
import SwiftUI
import ArcadeApp

/// 퀘스트 보드 전체 화면.
struct QuestBoardView: View {
    @Environment(\.arcadeTheme) private var theme
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Text("QUEST BOARD")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider().overlay(theme.line)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surfaceBase)
    }
}
```

- [ ] **Step 6: 플로어가 전체 화면 전환을 다루게 한다**

`ArcadeFloorView`의 `cabinets` 배열에 보드를 더한다:

```swift
    private var cabinets: [any Cabinet] {
        [QuestBoardCabinet(model: model), ObservationCabinet(model: model)]
    }
```

`comingSoon()` 호출을 두 개에서 하나로 줄인다 (칸이 세 개이므로).

전체 화면 상태를 더한다:

```swift
    @State private var fullScreenCabinetID: String?
```

`body`의 `VStack`을 전환으로 감싼다:

```swift
    var body: some View {
        Group {
            if let id = fullScreenCabinetID,
               let cabinet = cabinets.first(where: { $0.id == id }) {
                fullScreen(cabinet)
            } else {
                floor
            }
        }
        .background(theme.surfaceBase)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            Task { await model.syncNow(reason: .foreground) }
        }
    }

    /// 기존 플로어 화면. 이전 `body`의 내용을 그대로 옮긴 것이다.
    private var floor: some View {
        VStack(spacing: 0) {
            marquee
            Divider().overlay(theme.line)
            cabinetRow
            Divider().overlay(theme.line)
            statusBar
        }
        .sheet(item: Binding(
            get: { openCabinetID.map(OpenCabinet.init) },
            set: { openCabinetID = $0?.id }
        )) { open in
            // ...기존 시트 내용 그대로...
        }
    }

    /// 전체 화면 캐비닛. 상단 줄이 플로어로 돌아가는 유일한 길이다.
    private func fullScreen(_ cabinet: any Cabinet) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("◂ FLOOR") { fullScreenCabinetID = nil }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                    .keyboardShortcut(.cancelAction)
                Text(cabinet.title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.inkSecondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider().overlay(theme.line)
            cabinet.makeView()
        }
    }
```

`cabinetCard`의 열기 버튼이 표시 방식에 따라 갈리게 한다:

```swift
                Button("▶ OPEN") {
                    switch cabinet.presentation {
                    case .sheet:      openCabinetID = cabinet.id
                    case .fullScreen: fullScreenCabinetID = cabinet.id
                    }
                }
```

- [ ] **Step 7: 테스트가 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test
```

기대: 전체 PASS

- [ ] **Step 8: 앱을 띄워 눈으로 확인한다**

```bash
cd Packages/Jirarcade && swift run JirarcadeApp
```

확인: 플로어에 `QUEST BOARD` 칸이 생겼고, `▶ OPEN`을 누르면 시트가 아니라 화면 전체가
바뀐다. `◂ FLOOR`와 `Esc`로 돌아온다. `OBSERVATION`은 여전히 시트로 열린다.

- [ ] **Step 9: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeUI/ Packages/Jirarcade/Tests/ArcadeAppTests/ModuleBoundaryTests.swift
git commit -m "feat: 캐비닛 표시 방식과 퀘스트 보드 전체 화면 전환

Cabinet에 presentation을 더하고 기본값을 .sheet로 둬 ObservationCabinet은
건드리지 않는다. 보드만 .fullScreen을 돌려준다 — 매일 여러 번 여는 화면이라
minWidth 420 시트에 레인 넷과 축이 들어가지 않는다.

티켓 URL은 AtlassianLinks 한곳에서만 만든다. 토큰 페이지와 같은 규칙이며
소스 검사 테스트가 강제한다."
```

---
### Task 9: 축과 레인과 카드를 그린다

`BoardLayout`이 준 좌표를 화면에 놓는다. 뷰에 남는 판단은 "정규화 위치를 pt로 바꾼다"
뿐이고, 그 곱셈은 `BoardMetrics`에 모은다.

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/BoardMetrics.swift`
- Create: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/BoardAxisView.swift`
- Create: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/BoardLaneView.swift`
- Create: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/TicketCardView.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/QuestBoardView.swift`

**Interfaces:**
- Consumes: `BoardSnapshot`/`BoardLane`/`BoardSlot`/`AxisTick`/`DueState`/`StagnationTier` (Tasks 2–4), `AppModel.issues`·`statusEnteredAt`·`boardWorkflow` (Task 5)
- Produces:
  - `struct BoardMetrics { cardWidth, cardHeight, x(for:), y(forRow:), laneHeight(rowCount:), minimumSpacing }`
  - `BoardAxisView`, `BoardLaneView`, `TicketCardView`

- [ ] **Step 1: `BoardMetrics`를 만든다**

`Sources/ArcadeUI/QuestBoard/BoardMetrics.swift`:

```swift
import SwiftUI

/// 정규화 위치(0…1)를 pt로 옮기는 곱셈만 모은 값 타입.
///
/// 판단은 `BoardLayout`이 이미 끝냈다 — 여기에는 등급 판정도 정렬도 없다.
/// 그래서 `ArcadeUI`에 테스트 타깃이 없어도 위험이 낮다.
struct BoardMetrics {
    let availableWidth: Double

    let cardWidth: Double = 132
    let cardHeight: Double = 78
    let rowGap: Double = 8
    /// 카드 사이에 최소로 남길 여백. 이보다 좁아지면 `LanePacker`가 다음 줄로 내린다.
    let cardGap: Double = 10

    /// 카드가 놓일 수 있는 폭. position 1.0인 카드의 오른쪽 끝이 축의 끝과 맞는다.
    var usableWidth: Double { max(availableWidth - cardWidth, 1) }

    /// `BoardLayout.snapshot(minimumSpacing:)`에 넘길 값.
    /// 창을 좁히면 이 값이 커져 자연히 더 많이 쌓인다.
    var minimumSpacing: Double { (cardWidth + cardGap) / usableWidth }

    func x(for position: Double) -> Double { position * usableWidth }

    func y(forRow row: Int) -> Double { Double(row) * (cardHeight + rowGap) }

    /// 슬롯이 없으면 0이 아니라 한 줄 높이를 준다 — 빈 레인도 축은 그려야
    /// "여기에 아무것도 없다"가 보인다.
    func laneHeight(rowCount: Int) -> Double {
        Double(max(rowCount, 1)) * cardHeight + Double(max(rowCount - 1, 0)) * rowGap
    }
}
```

- [ ] **Step 2: 축을 그린다**

`Sources/ArcadeUI/QuestBoard/BoardAxisView.swift`:

```swift
import SwiftUI
import ArcadeCore

/// 정체 시간축의 눈금선과 라벨.
///
/// 눈금은 `RuleSet`의 등급 경계값이다. boss 경계부터 선을 굵게 해 "여기부터는
/// 다른 구역"임을 색을 더 쓰지 않고 말한다.
struct BoardAxisView: View {
    @Environment(\.arcadeTheme) private var theme
    let ticks: [AxisTick]
    let metrics: BoardMetrics
    /// boss 경계의 인덱스. 이 인덱스부터 선이 굵어진다.
    private var emphasisIndex: Int { max(ticks.count - 2, 0) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { index, tick in
                VStack(alignment: .leading, spacing: 2) {
                    Rectangle()
                        .fill(theme.line)
                        .frame(width: index >= emphasisIndex ? 2 : 1)
                        .frame(maxHeight: .infinity)
                    Text(tick.isTerminal ? "\(tick.days)d+" : "\(tick.days)d")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(theme.inkTertiary)
                        .fixedSize()
                }
                // 눈금선은 카드 왼쪽 모서리 기준이 아니라 축 전체 기준이다.
                .offset(x: tick.position * metrics.usableWidth)
            }
        }
    }
}
```

- [ ] **Step 3: 카드를 그린다**

`Sources/ArcadeUI/QuestBoard/TicketCardView.swift`:

```swift
import SwiftUI
import ArcadeCore

/// 축 위에 놓이는 티켓 한 장.
///
/// raid를 boss와 색으로 가르지 않고 **채움**으로 가르는 이유: 팔레트는 대비 테스트로
/// 확정돼 있고 raid 전용 토큰이 없다. `RootView.warningBanner`가 같은 판단을 이미 했다.
struct TicketCardView: View {
    @Environment(\.arcadeTheme) private var theme
    let slot: BoardSlot
    let metrics: BoardMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(tierLabel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(tierColor)
                Spacer()
                Text(stagnationLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.inkTertiary)
                    .monospacedDigit()
            }
            Text(slot.issue.key)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.inkPrimary)
            Text(slot.issue.summary)
                .font(.system(size: 10))
                .foregroundStyle(theme.inkSecondary)
                .lineLimit(2)
            if let due = dueLabel {
                Text(due)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(dueColor)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: metrics.cardWidth, height: metrics.cardHeight, alignment: .topLeading)
        .background(slot.tier == .raid ? theme.boss.opacity(0.18) : theme.surfaceRaised)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(tierColor, lineWidth: slot.tier >= .boss ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(slot.isApproximate
              ? "관측 이력이 없어 마지막 갱신 시각으로 추정한 정체일입니다"
              : slot.issue.summary)
    }

    private var tierLabel: String {
        switch slot.tier {
        case .fresh:  return "·"
        case .stale:  return "STALE"
        case .boss:   return "BOSS"
        case .raid:   return "RAID"
        }
    }

    private var tierColor: Color {
        switch slot.tier {
        case .fresh:  return theme.line
        case .stale:  return theme.accent
        case .boss, .raid: return theme.boss
        }
    }

    /// 근사값에 `~`를 붙인다. 관측 이력이 없는 티켓의 정체일을 확정처럼 보여주면
    /// "관측한 것만 안다"는 이 앱의 원칙이 화면에서 깨진다.
    private var stagnationLabel: String {
        (slot.isApproximate ? "~" : "") + "\(slot.daysStagnant)d"
    }

    private var dueLabel: String? {
        switch slot.dueState {
        case .none:                 return nil
        case .overdue(let days):    return "\(days)일 지남"
        case .dueIn(let days):      return days == 0 ? "오늘 마감" : "D-\(days)"
        }
    }

    /// 강조 기준은 뷰가 정한다(`ArcadeCore`는 사실만 담는다). D-3 이내부터 눈에 띄게 한다.
    private var dueColor: Color {
        switch slot.dueState {
        case .none:              return theme.inkTertiary
        case .overdue:           return theme.danger
        case .dueIn(let days):   return days <= 3 ? theme.accent : theme.inkTertiary
        }
    }
}
```

- [ ] **Step 4: 레인을 그린다**

`Sources/ArcadeUI/QuestBoard/BoardLaneView.swift`:

```swift
import SwiftUI
import ArcadeCore

/// 단계 하나의 레인 — 헤더 + 축 + 그 위에 놓인 카드들.
struct BoardLaneView: View {
    @Environment(\.arcadeTheme) private var theme
    let lane: BoardLane
    let axis: [AxisTick]
    let metrics: BoardMetrics
    /// WIP 한도. `active` 레인에만 표시한다.
    let wipLimit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ZStack(alignment: .topLeading) {
                BoardAxisView(ticks: axis, metrics: metrics)
                ForEach(lane.slots) { slot in
                    TicketCardView(slot: slot, metrics: metrics)
                        .offset(x: metrics.x(for: slot.position),
                                y: metrics.y(forRow: slot.row))
                }
            }
            .frame(height: metrics.laneHeight(rowCount: lane.rowCount),
                   alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(stageLabel)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.inkSecondary)
            Spacer()
            Text(countLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(overWIP ? theme.danger : theme.inkTertiary)
                .monospacedDigit()
        }
    }

    private var stageLabel: String {
        switch lane.stage {
        case .backlog: return "BACKLOG"
        case .active:  return "ACTIVE"
        case .review:  return "REVIEW"
        case .verify:  return "VERIFY"
        case .done:    return "DONE"
        }
    }

    private var overWIP: Bool {
        guard let wipLimit else { return false }
        return lane.slots.count > wipLimit
    }

    private var countLabel: String {
        guard let wipLimit else { return "\(lane.slots.count)건" }
        return overWIP
            ? "\(lane.slots.count)건 · 한도 \(wipLimit) ⚠"
            : "\(lane.slots.count)건 · 한도 \(wipLimit)"
    }
}
```

- [ ] **Step 5: 보드 본체를 조립한다**

`Sources/ArcadeUI/QuestBoard/QuestBoardView.swift`를 이것으로 교체한다:

```swift
import SwiftUI
import ArcadeApp
import ArcadeCore

/// 퀘스트 보드 전체 화면.
struct QuestBoardView: View {
    @Environment(\.arcadeTheme) private var theme
    let model: AppModel

    var body: some View {
        GeometryReader { geometry in
            // 축이 쓸 수 있는 폭. 좌우 여백을 빼고 남는 만큼이다.
            let metrics = BoardMetrics(availableWidth: max(geometry.size.width - 40, 200))
            let snapshot = BoardLayout.snapshot(
                issues: model.issues,
                statusEnteredAt: model.statusEnteredAt,
                workflow: model.boardWorkflow,
                rules: .default,
                minimumSpacing: metrics.minimumSpacing,
                now: Date(),
                calendar: .current
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(snapshot.lanes) { lane in
                        BoardLaneView(
                            lane: lane, axis: snapshot.axis, metrics: metrics,
                            wipLimit: lane.stage == .active ? RuleSet.default.wipLimit : nil
                        )
                    }
                }
                .padding(20)
            }
        }
        .background(theme.surfaceBase)
    }
}
```

> **주의:** `rules`와 `now`/`calendar`를 여기서 리터럴로 쓰는 것은 **Task 10에서 고친다.**
> 뷰가 `Date()`와 `Calendar.current`를 직접 부르는 것은 Global Constraints 위반이다.
> Task 10에서 `AppModel`이 스냅샷을 만들어 주도록 옮긴다.

- [ ] **Step 6: 빌드하고 눈으로 확인한다**

```bash
cd Packages/Jirarcade && swift build && swift run JirarcadeApp
```

확인: 보드를 열면 레인 네 개가 뜨고, 각 레인에 `0d / 7d / 21d / 45d+` 눈금이 있으며,
티켓이 정체일에 따라 좌우로 흩어진다. 창을 좁히면 카드가 겹치지 않고 아래로 쌓인다.
시스템 외관을 라이트/다크로 바꿔도 전부 읽힌다.

- [ ] **Step 7: 색 리터럴 검사가 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter viewsUseThemeTokens
```

기대: PASS. 실패하면 새 뷰 어딘가에 `Color.…`나 `.secondary`가 남은 것이다.

- [ ] **Step 8: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/
git commit -m "feat: 정체 시간축 위에 티켓 카드를 놓는다

BoardLayout이 준 정규화 좌표를 pt로 옮기는 곱셈만 BoardMetrics에 모은다 —
등급 판정도 정렬도 뷰에 없으므로 ArcadeUI에 테스트 타깃이 없어도 위험이 낮다.

minimumSpacing을 뷰가 계산해 넘긴다. 창을 좁히면 값이 커져 자연히 더 쌓인다.

raid는 boss와 색이 아니라 채움으로 가른다. 팔레트는 대비 테스트로 확정돼 있고
raid 전용 토큰이 없다."
```

---
### Task 10: HUD와 스냅샷 소유권 정리

Task 9의 뷰가 `Date()`와 `Calendar.current`를 직접 불렀다 — Global Constraints 위반이다.
스냅샷 생성을 `AppModel`로 옮긴다. 모델은 이미 `rules`·`clock`·`calendar`를 전부 들고 있다.

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift`
- Create: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/BoardHUDView.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/QuestBoardView.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/BoardStateTests.swift` (덧붙임)

**Interfaces:**
- Consumes: `BoardLayout.snapshot(...)` (Task 3–4), `AppModel.seasonSummary`·`hygiene` (기존 + Task 5)
- Produces:
  - `AppModel.boardSnapshot(minimumSpacing: Double) -> BoardSnapshot`
  - `AppModel.wipLimit: Int`
  - `BoardHUDView`

- [ ] **Step 1: 실패하는 테스트를 덧붙인다**

`BoardStateTests.swift` 끝에 추가한다:

```swift
/// 뷰가 시계와 달력을 직접 만들지 않도록 모델이 스냅샷을 준다.
@MainActor
@Test func buildsTheBoardSnapshotWithTheInjectedClock() async throws {
    let model = try makeModel(workflow: InMemoryWorkflowStore(seeded: demoWorkflow),
                              now: now)
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([
        issue(key: "DEMO-1", status: "In Progress",
              updated: now.addingTimeInterval(-days(30))),
    ])

    let snapshot = model.boardSnapshot(minimumSpacing: 0.1)

    #expect(snapshot.lanes.map(\.stage) == [.backlog, .active, .review, .verify])
    #expect(snapshot.lanes[1].slots.first?.daysStagnant == 30)
    #expect(snapshot.axis.map(\.days) == [0, 7, 21, 45])
}

@MainActor
@Test func exposesTheWIPLimitFromTheRuleSet() throws {
    let model = try makeModel(now: now)

    #expect(model.wipLimit == RuleSet.default.wipLimit)
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter BoardState
```

기대: 컴파일 실패 — `no member 'boardSnapshot'`

- [ ] **Step 3: `AppModel`에 스냅샷과 WIP 한도를 더한다**

`AppModel`에 추가한다 (`recomputeFromLog()` 위쪽, 공개 API 구역):

```swift
    /// 보드가 그릴 좌표. 뷰가 시계와 달력을 직접 만들지 않도록 모델이 만든다.
    ///
    /// 매 렌더마다 불린다. `BoardLayout.snapshot`은 순수 함수이고 티켓 수만큼만 도는
    /// 계산이라 미러 규모(수십~수백 건)에서는 문제가 없다 — 스토어를 치지 않는 것이
    /// 중요하고, 그래서 `issues`·`statusEnteredAt`·`boardWorkflow`를 미리 갖고 있는다.
    ///
    /// - Parameter minimumSpacing: 뷰가 카드 폭과 창 폭으로 계산해 넘긴다.
    public func boardSnapshot(minimumSpacing: Double) -> BoardSnapshot {
        BoardLayout.snapshot(
            issues: issues,
            statusEnteredAt: statusEnteredAt,
            workflow: boardWorkflow,
            rules: rules,
            minimumSpacing: minimumSpacing,
            now: clock(),
            calendar: calendar
        )
    }

    /// WIP 한도. 보드의 `active` 레인 헤더가 읽는다.
    /// 뷰가 `RuleSet.default`를 직접 보면 사용자가 규칙을 고쳐도 화면이 따라가지 않는다.
    public var wipLimit: Int { rules.wipLimit }
```

- [ ] **Step 4: HUD를 만든다**

`Sources/ArcadeUI/QuestBoard/BoardHUDView.swift`:

```swift
import SwiftUI
import ArcadeApp
import ArcadeCore

/// 보드 상단 한 줄 — 시즌 레벨·XP·연속·HP·위생과 다음 한 걸음.
///
/// 시즌을 보여주는 이유는 `ArcadeFloorView`와 같다: 오늘 하나 처리한 것이 움직여야 한다.
struct BoardHUDView: View {
    @Environment(\.arcadeTheme) private var theme
    let model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            if let season = model.seasonSummary {
                Text("LV.\(season.level)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.accent)
                ProgressView(value: Double(season.xpIntoLevel),
                             total: Double(max(season.xpForNextLevel, 1)))
                    .tint(theme.accent)
                    .frame(width: 110)
                Text("\(season.xpIntoLevel)/\(season.xpForNextLevel)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.inkTertiary)
                    .monospacedDigit()
                Text("연속 \(season.streak.currentStreak)일")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.inkSecondary)
                    .monospacedDigit()
            }
            if let hygiene = model.hygiene {
                Text(hpLabel(hygiene.hp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(hygiene.hp == 0 ? theme.danger : theme.good)
                Text("위생 \(hygiene.score)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.inkSecondary)
                    .monospacedDigit()
                if let step = hygiene.nextStep {
                    Text(nextStepLabel(step))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.inkTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func hpLabel(_ hp: Int) -> String {
        String(repeating: "♥", count: hp) + String(repeating: "♡", count: max(0, 3 - hp))
    }

    /// `HygieneNextStep`은 구조화된 값이다. 문장으로 만드는 일은 뷰가 한다 —
    /// `HygieneCalculator`의 doc-comment가 정한 경계다.
    private func nextStepLabel(_ step: HygieneNextStep) -> String {
        switch step {
        case .reduceWIP(let to, let gain):
            return "진행 중을 \(to)건까지 줄이면 위생 +\(gain)"
        case .touchZombies(let count, let gain):
            return "오래 멈춘 \(count)건을 움직이면 위생 +\(gain)"
        case .resolveGhosts(let count, let gain):
            return "마감 지난 \(count)건을 정리하면 위생 +\(gain)"
        }
    }
}
```

- [ ] **Step 5: 보드가 모델의 스냅샷을 쓰게 한다**

`QuestBoardView`의 `body`를 이것으로 교체한다:

```swift
    var body: some View {
        GeometryReader { geometry in
            let metrics = BoardMetrics(availableWidth: max(geometry.size.width - 40, 200))
            let snapshot = model.boardSnapshot(minimumSpacing: metrics.minimumSpacing)

            VStack(spacing: 0) {
                BoardHUDView(model: model)
                Divider().overlay(theme.line)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(snapshot.lanes) { lane in
                            BoardLaneView(
                                lane: lane, axis: snapshot.axis, metrics: metrics,
                                wipLimit: lane.stage == .active ? model.wipLimit : nil
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(theme.surfaceBase)
    }
```

`import ArcadeCore`는 `RuleSet` 참조가 사라졌으므로 필요 없으면 지운다.

- [ ] **Step 6: 뷰가 시계를 직접 만들지 않는지 확인한다**

```bash
rg 'Date\(\)|Calendar\.current' Packages/Jirarcade/Sources/ArcadeUI/
```

기대: 0건

- [ ] **Step 7: 테스트를 돌리고 눈으로 확인한다**

```bash
cd Packages/Jirarcade && swift test && swift run JirarcadeApp
```

기대: 전체 PASS. 보드 상단에 레벨·XP 바·연속·HP·위생과 다음 한 걸음이 한 줄로 뜬다.

- [ ] **Step 8: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift \
        Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/ \
        Packages/Jirarcade/Tests/ArcadeAppTests/BoardStateTests.swift
git commit -m "feat: 보드 HUD와 스냅샷 소유권을 모델로

뷰가 Date()와 Calendar.current를 직접 부르던 것을 AppModel.boardSnapshot으로
옮긴다. 모델은 이미 rules·clock·calendar를 들고 있고, 뷰가 시계를 만들면
테스트에서 시간을 고정할 수 없다.

WIP 한도도 모델이 노출한다 — 뷰가 RuleSet.default를 직접 보면 사용자가 규칙을
고쳐도 화면이 따라가지 않는다."
```

---

### Task 11: 전이 UI — 메뉴, 낙관적 이동, 카운트다운, 실패

카드에서 상태를 옮긴다. 대기 중인 전이는 미러 위에 **겹쳐** 그리고, 스토어는 건드리지 않는다.

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift` (낙관적 겹치기)
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/TicketCardView.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/BoardLaneView.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/TransitionTests.swift` (덧붙임)

**Interfaces:**
- Consumes: `AppModel.pendingTransitions`·`transitionFailures`·`requestTransition`·`cancelPendingTransition`·`availableTransitions`·`siteHost` (Tasks 5–7), `AtlassianLinks.issue(key:site:)` (Task 8)
- Produces: `AppModel.boardSnapshot`이 대기 중인 전이를 반영한다

- [ ] **Step 1: 실패하는 테스트를 덧붙인다**

`TransitionTests.swift` 끝에 추가한다:

```swift
/// 대기 중인 전이는 카드를 새 레인으로 옮겨 그린다. 스토어는 건드리지 않으므로
/// 취소하면 그냥 원래 자리로 돌아온다 — 되돌릴 것이 없다.
@MainActor
@Test func aPendingTransitionMovesTheCardOptimistically() async throws {
    let sleeper = ManualSleep()
    let model = try makeModel(
        workflow: InMemoryWorkflowStore(seeded: demoWorkflow),
        http: { ScriptedHTTP([.init(status: 200, body: Data(myselfBody.utf8))]) },
        now: now,
        transitionSleep: { try await sleeper.sleep($0) }
    )
    await model.signIn(site: "example.atlassian.net", email: "t@example.com", token: "tok")
    model.seedIssuesForTesting([issue(key: "DEMO-1", status: "In Progress")])

    model.requestTransition(issueKey: "DEMO-1",
                            transition: try transition(id: "21", name: "리뷰로", to: "In Review"))
    let moved = model.boardSnapshot(minimumSpacing: 0.1)

    #expect(moved.lanes[1].slots.isEmpty, "ACTIVE에 남아 있다")
    #expect(moved.lanes[2].slots.map(\.issue.key) == ["DEMO-1"], "REVIEW로 옮겨지지 않았다")

    model.cancelPendingTransition(issueKey: "DEMO-1")
    let restored = model.boardSnapshot(minimumSpacing: 0.1)

    #expect(restored.lanes[1].slots.map(\.issue.key) == ["DEMO-1"])
    #expect(restored.lanes[2].slots.isEmpty)
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter aPendingTransitionMoves
```

기대: FAIL — 카드가 ACTIVE에 그대로 있다

- [ ] **Step 3: 낙관적 겹치기를 더한다**

`AppModel.boardSnapshot`의 `issues:` 인자를 `optimisticIssues`로 바꾸고, 아래 계산
프로퍼티를 더한다:

```swift
    /// 대기 중인 전이를 미러 위에 **겹친** 목록.
    ///
    /// 스토어를 건드리지 않는 것이 핵심이다 — 롤백은 `pendingTransitions`에서 지우는
    /// 것이고, Jira에는 아직 아무것도 보내지 않았으므로 되돌릴 것도 없다.
    private var optimisticIssues: [ObservedIssue] {
        guard !pendingTransitions.isEmpty else { return issues }
        return issues.map { issue in
            guard let pending = pendingTransitions[issue.key] else { return issue }
            // `ObservedIssue`는 전부 `let`이라 상태명만 바꾼 사본을 만든다.
            // `jiraUpdatedAt`은 **건드리지 않는다** — 아직 Jira에서 아무 일도 일어나지
            // 않았고, 여기서 지금 시각으로 밀면 정체일이 0으로 보였다가 실패 시
            // 되돌아오는 깜빡임이 생긴다.
            return ObservedIssue(
                key: issue.key, summary: issue.summary,
                statusName: pending.toStatusName, issueType: issue.issueType,
                priority: issue.priority, assigneeAccountId: issue.assigneeAccountId,
                assigneeName: issue.assigneeName, dueDate: issue.dueDate,
                jiraUpdatedAt: issue.jiraUpdatedAt
            )
        }
    }
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter Transition
```

기대: 10 tests PASS

- [ ] **Step 5: 카드에 전이 메뉴와 대기 표시를 더한다**

`TicketCardView`에 프로퍼티를 더한다:

```swift
    let model: AppModel
    let pending: PendingTransition?
    let failure: String?
```

`body`의 `VStack` 마지막(`Spacer(minLength: 0)` 앞)에 넣는다:

```swift
            if let pending {
                HStack(spacing: 4) {
                    Text("→ \(pending.toStatusName)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                    Spacer()
                    Button("취소") { model.cancelPendingTransition(issueKey: slot.issue.key) }
                        .font(.system(size: 9, design: .monospaced))
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.danger)
                }
            } else if let failure {
                // Jira가 준 사유는 담지 않는다(AppModel.transitionFailureMessage 참고).
                // 대신 그 정보를 채울 수 있는 곳으로 보낸다.
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure)
                        .font(.system(size: 9))
                        .foregroundStyle(theme.danger)
                        .lineLimit(2)
                    if let url = jiraURL {
                        Link("Jira에서 열기", destination: url)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(theme.accent)
                    }
                }
            } else {
                transitionMenu
            }
```

메뉴와 링크를 더한다:

```swift
    /// 전이 후보는 **메뉴를 열 때** 받아온다. 캐싱하지 않는 이유: 관리자가 워크플로를
    /// 바꾸면 캐시된 전이 ID는 즉시 틀린 값이 된다(v0.1 스펙 §8.5).
    @State private var transitions: [JiraTransition] = []
    @State private var isLoadingTransitions = false

    private var transitionMenu: some View {
        Menu {
            if isLoadingTransitions {
                Text("불러오는 중…")
            } else if transitions.isEmpty {
                Text("옮길 수 있는 상태가 없습니다")
            } else {
                ForEach(transitions, id: \.id) { transition in
                    Button(transition.name) {
                        model.requestTransition(issueKey: slot.issue.key, transition: transition)
                    }
                }
            }
            if let url = jiraURL {
                Divider()
                Link("Jira에서 열기", destination: url)
            }
        } label: {
            Text("상태 옮기기")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(theme.inkTertiary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onTapGesture { loadTransitions() }
    }

    private var jiraURL: URL? {
        guard let site = model.siteHost else { return nil }
        return AtlassianLinks.issue(key: slot.issue.key, site: site)
    }

    private func loadTransitions() {
        guard !isLoadingTransitions else { return }
        isLoadingTransitions = true
        Task {
            transitions = (try? await model.availableTransitions(for: slot.issue.key)) ?? []
            isLoadingTransitions = false
        }
    }
```

`import JiraKit`을 파일 상단에 더한다 (`JiraTransition` 때문).

- [ ] **Step 6: 레인이 대기와 실패를 카드에 넘기게 한다**

`BoardLaneView`에 `let model: AppModel`을 더하고 `import ArcadeApp`을 추가한 뒤,
`TicketCardView` 생성을 이렇게 바꾼다:

```swift
                    TicketCardView(
                        slot: slot, metrics: metrics, model: model,
                        pending: model.pendingTransitions[slot.issue.key],
                        failure: model.transitionFailures[slot.issue.key]
                    )
```

`QuestBoardView`의 `BoardLaneView(...)` 호출에도 `model: model`을 더한다.

- [ ] **Step 7: 카드 높이를 늘린다**

전이 줄이 들어가면서 `cardHeight: 78`로는 내용이 잘린다. `BoardMetrics`에서
`cardHeight`를 `96`으로 올린다.

- [ ] **Step 8: 카드 이동에 모션을 준다**

스펙 §8: **모션은 전이 하나에만 쓴다.** 카드가 레인 사이를 이동하는 것이 유일한
애니메이션이고, 취소하면 같은 경로를 되돌아간다 — 그 되돌아감이 "아직 Jira에
아무 일도 없었다"를 말한다. 흩어진 효과를 더하면 그 문장이 묻힌다.

`BoardLaneView`의 카드 배치에 위치 애니메이션을 건다:

```swift
                ForEach(lane.slots) { slot in
                    TicketCardView(
                        slot: slot, metrics: metrics, model: model,
                        pending: model.pendingTransitions[slot.issue.key],
                        failure: model.transitionFailures[slot.issue.key]
                    )
                    .offset(x: metrics.x(for: slot.position),
                            y: metrics.y(forRow: slot.row))
                    // 레인이 달라져도 같은 카드로 인식되게 한다. 이 id가 없으면
                    // SwiftUI가 옛 카드를 지우고 새 카드를 그려 이동이 보이지 않는다.
                    .matchedGeometryEffect(id: slot.issue.key, in: cardNamespace)
                }
```

`BoardLaneView`에 네임스페이스를 받는다:

```swift
    let cardNamespace: Namespace.ID
```

`QuestBoardView`가 소유하고 넘긴다:

```swift
    @Namespace private var cardNamespace
```

```swift
                            BoardLaneView(
                                lane: lane, axis: snapshot.axis, metrics: metrics,
                                model: model, cardNamespace: cardNamespace,
                                wipLimit: lane.stage == .active ? model.wipLimit : nil
                            )
```

그리고 `ScrollView`를 감싼 `VStack`에 애니메이션을 건다. **`reduceMotion`을 존중한다** —
켜져 있으면 위치만 즉시 바뀐다:

```swift
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
```

```swift
                .animation(reduceMotion ? nil : .spring(duration: 0.35),
                           value: model.pendingTransitions)
```

`PendingTransition`이 `Equatable`이므로 딕셔너리 전체를 `value:`로 쓸 수 있다.

- [ ] **Step 9: 테스트를 돌리고 눈으로 확인한다**

```bash
cd Packages/Jirarcade && swift test && swift run JirarcadeApp
```

확인:
- 카드의 `상태 옮기기`를 누르면 전이 후보가 뜬다
- 하나를 고르면 카드가 즉시 다른 레인으로 이동하고 `취소`가 뜬다
- 5초 안에 `취소`를 누르면 원래 레인으로 돌아온다. **Jira 웹을 새로고침해도 변화가 없다**
- 취소하지 않으면 5초 뒤 Jira에 반영되고, 동기화 후 카드가 새 레인에 머문다

- [ ] **Step 10: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift \
        Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/ \
        Packages/Jirarcade/Tests/ArcadeAppTests/TransitionTests.swift
git commit -m "feat: 카드에서 상태를 옮긴다

대기 중인 전이를 미러 위에 겹쳐 그린다. 스토어를 건드리지 않으므로 취소는
pendingTransitions에서 지우는 것이 전부다 — Jira에 아직 아무것도 보내지 않았다.

jiraUpdatedAt은 낙관적 표시에서도 건드리지 않는다. 지금 시각으로 밀면 정체일이
0으로 보였다가 실패 시 되돌아오는 깜빡임이 생긴다.

전이 후보는 메뉴를 열 때 받아오고 캐싱하지 않는다 — 관리자가 워크플로를 바꾸면
캐시된 ID는 즉시 틀린 값이 된다.

모션은 카드 이동 하나뿐이다. 취소하면 같은 경로를 되돌아가고, 그 되돌아감이
아직 Jira에 아무 일도 없었다고 말한다. reduceMotion이 켜져 있으면 즉시 바뀐다."
```

---
### Task 12: 매핑되지 않은 티켓과 빈 상태

`workflow.stage(for:)`가 nil인 티켓은 어느 레인에도 들어가지 못한다. 그대로 두면
보드에서 조용히 사라지고 사용자는 티켓이 없어졌다고 생각한다.

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/UnmappedLaneView.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/QuestBoardView.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/ModuleBoundaryTests.swift` (덧붙임)

**Interfaces:**
- Consumes: `BoardSnapshot.unmappedIssues` (Task 3), `AppModel.reopenMapping()` (기존), `AppModel.lastSync` (기존)
- Produces: `UnmappedLaneView`

- [ ] **Step 1: 실패하는 테스트를 덧붙인다**

`ModuleBoundaryTests.swift`에 추가한다:

```swift
/// 매핑되지 않은 티켓을 보드가 반드시 보여준다. 어느 레인에도 들어가지 못하므로
/// 화면이 따로 다루지 않으면 조용히 사라지고, 사용자는 티켓이 없어졌다고 생각한다.
@Test func theBoardSurfacesUnmappedIssues() throws {
    let file = sourcesDirectory()
        .appendingPathComponent("ArcadeUI")
        .appendingPathComponent("QuestBoard")
        .appendingPathComponent("QuestBoardView.swift")
    let text = try String(contentsOf: file, encoding: .utf8)

    #expect(text.contains("unmappedIssues"),
            "보드가 BoardSnapshot.unmappedIssues를 읽지 않는다 — 티켓이 조용히 사라진다")
}

/// 매핑 마법사로 가는 길이 보드 안에 있어야 한다. 설정을 거치게 하면 사용자가
/// 문제를 본 자리에서 고칠 수 없다.
@Test func theUnmappedLaneLinksToTheMappingWizard() throws {
    let file = sourcesDirectory()
        .appendingPathComponent("ArcadeUI")
        .appendingPathComponent("QuestBoard")
        .appendingPathComponent("UnmappedLaneView.swift")
    let text = try String(contentsOf: file, encoding: .utf8)

    #expect(text.contains("reopenMapping"),
            "매핑되지 않은 레인에 마법사로 가는 길이 없다")
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd Packages/Jirarcade && swift test --filter "Unmapped"
```

기대: FAIL — `UnmappedLaneView.swift`가 없다

- [ ] **Step 3: 미매핑 레인을 만든다**

`Sources/ArcadeUI/QuestBoard/UnmappedLaneView.swift`:

```swift
import SwiftUI
import ArcadeApp
import ArcadeCore

/// 어느 단계에도 매핑되지 않은 상태의 티켓.
///
/// 접어 두는 이유: 이 목록이 비어 있는 것이 정상이고, 늘 펼쳐 두면 레인 넷보다
/// 먼저 눈에 들어온다. 개수는 접힌 상태에서도 항상 보인다.
struct UnmappedLaneView: View {
    @Environment(\.arcadeTheme) private var theme
    let issues: [ObservedIssue]
    let model: AppModel

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(isExpanded ? "▾ 매핑되지 않은 상태" : "▸ 매핑되지 않은 상태")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.danger)
                    Spacer()
                    // 플로어 마퀴의 배지는 **상태 개수**를 센다. 여기는 티켓 건수다 —
                    // 두 숫자는 다를 수 있으므로 문구로 구분한다.
                    Text("티켓 \(issues.count)건")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.inkTertiary)
                        .monospacedDigit()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(issues) { issue in
                        HStack(spacing: 8) {
                            Text(issue.key)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(theme.inkPrimary)
                            Text(issue.statusName)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.danger)
                            Text(issue.summary)
                                .font(.system(size: 10))
                                .foregroundStyle(theme.inkSecondary)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    // 마법사는 phase를 바꾸므로 RootView가 화면 전체를 갈아끼우고 보드는
                    // 닫힌다. 마치면 플로어로 돌아오며 사용자가 보드를 다시 연다.
                    Button("매핑 고치기") { Task { await model.reopenMapping() } }
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.top, 4)
                }
                .padding(.leading, 12)
            }
        }
        .padding(12)
        .background(theme.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.danger, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
```

- [ ] **Step 4: 보드에 붙이고 빈 상태를 더한다**

`QuestBoardView`의 `ScrollView` 안 `VStack`을 이렇게 바꾼다:

```swift
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if model.issues.isEmpty {
                            emptyState
                        } else {
                            ForEach(snapshot.lanes) { lane in
                                BoardLaneView(
                                    lane: lane, axis: snapshot.axis, metrics: metrics,
                                    model: model, cardNamespace: cardNamespace,
                                    wipLimit: lane.stage == .active ? model.wipLimit : nil
                                )
                            }
                        }
                        if !snapshot.unmappedIssues.isEmpty {
                            UnmappedLaneView(issues: snapshot.unmappedIssues, model: model)
                        }
                    }
                    .padding(20)
                }
```

빈 상태를 더한다:

```swift
    /// 동기화 전과 "티켓이 없다"를 구분한다. `ObservationCabinet`이 쓰는 것과 같은
    /// 판정(`lastSync`)이다 — 집계값으로 판정하면 백필이 넣은 이벤트 때문에 이 안내가
    /// 영영 뜨지 않는다.
    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.lastSync == nil {
                Text("아직 동기화하지 않았습니다.")
                    .font(.callout)
                    .foregroundStyle(theme.inkSecondary)
                Text("첫 동기화가 끝나면 담당한 티켓이 여기 나타납니다.")
                    .font(.callout)
                    .foregroundStyle(theme.inkTertiary)
            } else {
                Text("담당한 미완료 티켓이 없습니다.")
                    .font(.callout)
                    .foregroundStyle(theme.inkSecondary)
                Text("Jira에서 티켓을 맡으면 다음 동기화에 나타납니다.")
                    .font(.callout)
                    .foregroundStyle(theme.inkTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 40)
    }
```

`ObservedIssue`가 `Identifiable`이므로 `ForEach(issues)`가 그대로 된다.

- [ ] **Step 5: 테스트를 돌린다**

```bash
cd Packages/Jirarcade && swift test
```

기대: 전체 PASS

- [ ] **Step 6: 눈으로 확인한다**

```bash
cd Packages/Jirarcade && swift run JirarcadeApp
```

확인:
- 매핑되지 않은 상태의 티켓이 있으면 보드 하단에 접힌 줄이 뜨고, 펼치면 목록과
  `매핑 고치기`가 나온다
- `매핑 고치기`를 누르면 마법사가 열리고, 마치면 플로어로 돌아온다
- 티켓이 0건이면 동기화 전인지 아닌지에 따라 다른 문구가 뜬다

- [ ] **Step 7: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/ \
        Packages/Jirarcade/Tests/ArcadeAppTests/ModuleBoundaryTests.swift
git commit -m "feat: 매핑되지 않은 티켓 레인과 빈 상태

stage(for:)가 nil인 티켓은 어느 레인에도 들어가지 못한다. 화면이 따로 다루지
않으면 조용히 사라지고 사용자는 티켓이 없어졌다고 생각한다.

개수 문구를 '티켓 N건'으로 쓴다 — 플로어 마퀴의 배지는 상태 개수를 세므로 두
숫자가 다를 수 있고, 같은 문구를 쓰면 어느 쪽이 틀렸다고 읽힌다.

빈 상태는 lastSync로 동기화 전과 티켓 없음을 가른다. 집계값으로 판정하면
백필이 넣은 이벤트 때문에 안내가 영영 뜨지 않는다."
```

---

### Task 13: 완성 정의 확인과 문서 갱신

스펙 §11의 완성 정의를 하나씩 확인하고 README를 갱신한다.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 전체 테스트를 돌린다**

```bash
cd Packages/Jirarcade && swift test 2>&1 | tail -20
```

기대: 전체 PASS. 실패가 있으면 여기서 멈추고 고친다.

- [ ] **Step 2: 완성 정의를 손으로 확인한다**

`swift run JirarcadeApp`으로 띄우고 스펙 §11의 항목을 순서대로 확인한다:

```
□ 플로어에서 QUEST BOARD를 열면 내 미완료 티켓이 단계별 레인에 전량 뜬다
□ 티켓이 정체일에 따라 축 위에 놓이고, 눈금이 RuleSet의 경계값과 일치한다
□ 규칙 JSON에서 bossDays를 바꾸면 축 눈금과 등급이 함께 움직인다
□ 관측 이력이 없는 티켓의 정체일에 근사 표시(~)가 붙는다
□ 매핑되지 않은 상태의 티켓이 보드에서 사라지지 않는다
□ 카드에서 상태를 옮기면 5초 안에 취소할 수 있고, 취소하면 Jira에 아무 일도 없다
□ 5초가 지나 전이가 성공하면 Jira 웹에서 확인되고, 다음 동기화에서 XP가 붙는다
□ 전이가 실패하면 카드가 제자리로 돌아가고 안내와 Jira 링크가 뜨며 XP가 없다
□ 어떤 화면 문구에도 Jira 응답 본문 조각이 섞이지 않는다
□ 라이트/다크 모두에서 읽히며 뷰 코드에 색 리터럴이 없다
□ swift test 전부 통과
```

세 번째 항목은 설정 화면의 규칙 JSON 편집으로 확인한다. `bossDays`를 10으로 낮추면
축의 세 번째 눈금이 `10d`가 되고, 10일 이상 정체한 티켓이 `BOSS`로 바뀌어야 한다.

스펙 §7.4의 오프라인 동작도 여기서 함께 본다 — v0.1 완성 정의의 "네트워크를 끊어도
앱이 열리고 마지막 미러를 보여준다"가 이 화면에서 처음 실제 의미를 갖는다:

```
□ Wi-Fi를 끄고 앱을 재실행해도 보드가 마지막 미러로 그려진다
□ 그 상태에서 `상태 옮기기`를 누르면 후보가 비고, 앱이 멈추지 않는다
```

`reduceMotion`도 확인한다 — 시스템 설정 > 손쉬운 사용 > 디스플레이 > 동작 줄이기를
켜면 카드가 애니메이션 없이 즉시 이동해야 한다.

- [ ] **Step 3: README를 갱신한다**

`README.md`의 "현재 할 수 있는 것" 절에서 다음을 옮긴다.

"동작합니다"에 추가:

```markdown
- 퀘스트 보드 — 내 티켓을 단계별 레인에 정체 시간축으로 배치
- 카드에서 상태 전이 (5초 실행 취소, XP는 다음 동기화에서 붙음)
```

"아직 없습니다"에서 제거:

```markdown
- 퀘스트 보드 캐비닛 (내 티켓을 카드로 늘어놓는 본체)
```

그리고 다음으로 바꾼다:

```markdown
- 티켓 상세 — 제목·본문 수정과 댓글 (계획 2b-2)
- 스프린트 보드 (계획 2b-3)
```

상단 상태 줄도 고친다:

```markdown
> **상태:** 개발 중. 로그인 → 워크플로 매핑 → 아케이드 플로어 → 퀘스트 보드까지 동작합니다.
> 티켓 상세·댓글·스프린트 보드는 아직 없습니다([스코프](#현재-할-수-있는-것) 참고).
```

"구조" 절의 디렉터리 트리에 보드를 더한다:

```
│   ├── ArcadeCore/     게임 규칙 · 스냅샷 diff · 보드 배치 · SwiftData 저장소
```

테스트 개수도 실제 값으로 고친다 (`swift test`의 마지막 줄이 알려준다).

- [ ] **Step 4: 커밋**

```bash
git add README.md
git commit -m "docs: 퀘스트 보드를 동작하는 기능으로 옮긴다"
```

---

## 완성 확인

이 계획이 끝나면 다음이 참이다:

- `swift test`가 전부 통과하고, 보드 배치 로직(`BoardAxis`·`LanePacker`·`BoardLayout`·
  `StatusTimeline`)과 전이 파이프라인이 전부 테스트로 덮인다
- `ArcadeUI`에 남은 무커버 코드는 좌표 곱셈과 문자열 포맷뿐이다
- 앱에서 실행한 전이가 Jira 웹에서 확인되고, 5초 안에 취소하면 흔적이 남지 않는다
- XP 부여 경로가 여전히 하나뿐이다 — 관측된 diff에서만 나온다

## 다음 계획

- **2b-2** 티켓 상세 · 제목/본문 수정 · 댓글 — ADF 처리와 XP 규칙 재검토가 선행 과제다
- **2b-3** 스프린트 보드 — `AuthProvider.baseURL`이 `/rest/api/3`에 묶여 있어 계약 변경이 선행한다
