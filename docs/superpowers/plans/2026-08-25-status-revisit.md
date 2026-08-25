# 되돌아온 티켓을 카드에 드러낸다 — 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 이미 거쳐 간 상태로 돌아온 티켓을 카드에 표시하고, 오조작 되돌림이 정체 기준선을 지우지 않게 한다.

**Architecture:** `AbuseGuard` 안에 있던 되돌림 판정을 순수 함수로 꺼내, 채점 층과 시간축 층이 같은 감지기를 본다. 왕복 횟수는 이벤트 로그에서 계산해 `statusEnteredAt`과 같은 길로 카드까지 간다. 카드에는 새 줄을 만들지 않고 정체일 라벨 옆에 붙인다.

**Tech Stack:** Swift 6.2, SwiftUI, SwiftData, Swift Testing (`@Test` / `#expect`)

**Spec:** `docs/superpowers/specs/2026-08-25-status-revisit-design.md`

## Global Constraints

- 모듈 의존은 단방향이다: `ArcadeUI → ArcadeApp → ArcadeCore → JiraKit`. 역방향 import 금지.
- **`ArcadeApp`은 SwiftUI를 import하지 않는다.** `ModuleBoundaryTests`가 소스 텍스트로 강제한다.
- **`ArcadeUI`에는 테스트 타깃이 없다.** 판단이 뷰에 들어가면 어떤 테스트도 닿지 못한다. 뷰에는 문자열 보간과 좌표 계산만 둔다.
- **`ArcadeUI`는 `.font(`와 `.system(size:`를 쓰지 않는다.** `arcadeType(_:_:weight:)`만 쓴다. `ModuleBoundaryTests.viewsUseTheTypeScaleRatherThanHardcodedFontSizes`가 소스 텍스트로 강제한다.
- 조직 특정 정보(실제 사이트 주소·프로젝트 키·커스텀 상태명)를 코드·테스트·README에 넣지 않는다. `example.atlassian.net`과 `DEMO-`만 쓴다.
- **왕복 횟수는 표시 전용이다.** `XpAwarder`·`HygieneCalculator`·`ScoreEngine`·`AbuseGuard`의 입력이 되지 않는다.
- **`AbuseGuard`의 기존 테스트는 무편집으로 통과해야 한다.** 추출은 동작을 바꾸지 않는 이동이다.
- 테스트는 Swift Testing(`@Test` / `#expect`)을 쓴다. XCTest를 쓰지 않는다.
- **코드 주석에 설계문서 § 참조를 넣지 않는다.** 이유는 문장으로 남기고 인용만 뺀다.
- 각 태스크는 `swift test` 전체 통과 후 커밋으로 끝난다.
- 테스트 실행은 절대 경로로: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`. 현재 **658개**, 약 6초.
- SourceKit 진단은 모듈 경계를 넘으면 낡은 정보를 보여준다. `swift test`로 판단한다.

## 파일 구조

**신규**

| 파일 | 책임 |
|---|---|
| `Sources/ArcadeCore/Rules/RevertDetector.swift` | 되돌림 쌍의 위치를 찾는다. 순수 함수 |
| `Sources/ArcadeCore/Domain/StatusRevisits.swift` | 티켓별 "이미 거친 상태로 돌아온" 횟수 |

**수정**

| 파일 | 무엇을 |
|---|---|
| `Sources/ArcadeCore/Rules/AbuseGuard.swift` | `voidReverts`가 감지기에 위임 |
| `Sources/ArcadeCore/Domain/StatusTimeline.swift` | 되돌림 쌍을 건너뛴다 |
| `Sources/ArcadeCore/Rules/ScoreEngine.swift` | 순회도 같은 제외를 거친다 |
| `Sources/ArcadeCore/Board/BoardLayout.swift` | `BoardSlot.revisits`와 `snapshot`의 인자 |
| `Sources/ArcadeCore/Board/LanePacker.swift` | `BoardSlot` 재생성 시 새 필드 전달 |
| `Sources/ArcadeApp/AppModel.swift` | `statusRevisits` 산출·보관·정리 |
| `Sources/ArcadeUI/QuestBoard/TicketCardView.swift` | `⇄N` 표시와 툴팁 |

## 태스크 순서 제약

**Task 1이 먼저다.** Task 2와 Task 3이 모두 `RevertDetector`를 쓴다.

**Task 3이 채점을 움직인다.** 기준선이 달라지면 `wakeXP`의 정체 배수가 달라진다. 의도된 변화이지만 크기를 재야 하므로, Task 3에서 실측하고 Task 7이 기록한다.

---

### Task 1: 되돌림 감지를 순수 함수로 꺼낸다

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Rules/RevertDetector.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Rules/AbuseGuard.swift` (`voidReverts`)
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/RevertDetectorTests.swift`

**Interfaces:**
- Consumes: `DomainEvent`(`issueKey`, `kind`, `fromStatus`, `toStatus`, `observedAt`), `EventKind.statusChanged`
- Produces: `RevertDetector.revertedIndices(in:windowMinutes:) -> Set<Int>`

**이 태스크의 성격:** 순수한 이동이다. **동작이 바뀌면 안 된다.** `AbuseGuard`의 기존 테스트가 검증 장치이며, 하나라도 깨지면 이동이 잘못된 것이다 — 테스트를 고치지 말고 이동을 의심한다.

**현재 로직**(`AbuseGuard.swift`, `voidReverts`): 시간순으로 순회하며 각 `.statusChanged` 이벤트에 대해 **뒤에서 앞으로** 같은 티켓의 `.statusChanged`를 찾는다. 창을 벗어나면 `break`, 정확한 역방향(`earlier.fromStatus == later.toStatus && earlier.toStatus == later.fromStatus`)이면 둘 다 0점 처리하고 `break`.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/ArcadeCoreTests/RevertDetectorTests.swift`를 만든다.

```swift
import Testing
import Foundation
@testable import ArcadeCore

private func change(
    _ key: String, from: String, to: String, at: String
) -> DomainEvent {
    DomainEvent(issueKey: key, kind: .statusChanged, fromStatus: from, toStatus: to,
                observedAt: iso(at), actorAccountId: "acc-me")
}

@Test func findsAnExactReversalInsideTheWindow() {
    let events = [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-20T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-20T09:05:00Z"),
    ]

    #expect(RevertDetector.revertedIndices(in: events, windowMinutes: 10) == [0, 1])
}

/// 창을 벗어난 왕복은 되돌림이 아니다. 리뷰 반려처럼 시간이 걸린 복귀는 진짜 움직임이다.
@Test func aReversalOutsideTheWindowIsNotARevert() {
    let events = [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-20T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-20T09:30:00Z"),
    ]

    #expect(RevertDetector.revertedIndices(in: events, windowMinutes: 10).isEmpty)
}

/// 정확한 역방향이어야 한다. 다른 상태로 갔다가 돌아온 것은 되돌림이 아니다.
@Test func aDifferentDestinationIsNotARevert() {
    let events = [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-20T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "완료", at: "2026-08-20T09:05:00Z"),
    ]

    #expect(RevertDetector.revertedIndices(in: events, windowMinutes: 10).isEmpty)
}

/// 티켓이 다르면 짝이 되지 않는다.
@Test func eventsOnDifferentIssuesDoNotPair() {
    let events = [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-20T09:00:00Z"),
        change("DEMO-2", from: "검토", to: "진행 중", at: "2026-08-20T09:05:00Z"),
    ]

    #expect(RevertDetector.revertedIndices(in: events, windowMinutes: 10).isEmpty)
}

/// 반환값은 **넘긴 배열 기준의 인덱스**다. 입력이 시간순이 아니어도 위치가 맞아야 한다.
@Test func indicesReferToThePassedArrayNotSortedOrder() {
    let events = [
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-20T09:05:00Z"),
        change("DEMO-9", from: "대기", to: "진행 중", at: "2026-08-19T09:00:00Z"),
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-20T09:00:00Z"),
    ]

    #expect(RevertDetector.revertedIndices(in: events, windowMinutes: 10) == [0, 2])
}

/// 상태를 모르는 이벤트는 짝이 될 수 없다.
@Test func eventsWithoutStatusesDoNotPair() {
    let events = [
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: nil, toStatus: "검토",
                    observedAt: iso("2026-08-20T09:00:00Z"), actorAccountId: nil),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-20T09:05:00Z"),
    ]

    #expect(RevertDetector.revertedIndices(in: events, windowMinutes: 10).isEmpty)
}
```

**확인된 것:** `iso(_:)`는 `Tests/ArcadeCoreTests/TestSupport.swift`에 이미 있다. 새로 만들지 않는다.

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter RevertDetectorTests`

Expected: FAIL — `RevertDetector`가 없어 컴파일되지 않는다.

- [ ] **Step 3: 감지기를 만든다**

`Sources/ArcadeCore/Rules/RevertDetector.swift`:

```swift
import Foundation

/// 되돌림 쌍에 속한 이벤트의 **위치**를 찾는다.
///
/// 같은 티켓에서 A→B 직후 창 안에 B→A가 관측되면 그 둘을 한 쌍으로 본다. 오조작을
/// 즉시 되돌린 흔적이며, 티켓은 실제로 어디에도 가지 않았다.
///
/// **왜 따로 있나:** 채점은 이 쌍의 XP를 0으로 만들고, 시간축은 이 쌍이 정체 기준선을
/// 밀지 않게 한다. 판정이 두 곳에 복사되면 한 쌍을 두 층이 다르게 보게 되고, 그것이
/// "XP는 막혔는데 정체일은 리셋된다"는 증상의 원인이었다.
///
/// **`DomainEvent`에는 안정적인 식별자가 없고 `Hashable`도 아니라** 위치로 가리킨다.
/// 반환값은 넘긴 배열 기준의 인덱스이므로, 호출자는 인덱싱할 그 배열을 그대로 넘겨야 한다.
public enum RevertDetector {
    public static func revertedIndices(
        in events: [DomainEvent],
        windowMinutes: Double
    ) -> Set<Int> {
        let window = windowMinutes * 60
        // 판정은 시간순으로 하되 반환은 원래 위치로 한다 — 호출자가 그 배열을 인덱싱한다.
        let order = events.indices.sorted {
            events[$0].observedAt < events[$1].observedAt
        }

        var paired: Set<Int> = []

        for (position, index) in order.enumerated() {
            let later = events[index]
            guard later.kind == .statusChanged else { continue }

            for earlierIndex in order[..<position].reversed() {
                let earlier = events[earlierIndex]
                guard earlier.kind == .statusChanged, earlier.issueKey == later.issueKey
                else { continue }
                guard later.observedAt.timeIntervalSince(earlier.observedAt) <= window
                else { break }

                if earlier.fromStatus == later.toStatus, earlier.toStatus == later.fromStatus,
                   earlier.fromStatus != nil, earlier.toStatus != nil {
                    paired.insert(earlierIndex)
                    paired.insert(index)
                    break
                }
            }
        }

        return paired
    }
}
```

**원본과 의도적으로 다른 곳이 한 곳뿐이다.** `earlier.fromStatus != nil, earlier.toStatus != nil` 가드를 더했다. Swift에서 `nil == nil`은 참이라, 두 이벤트의 상태가 모두 `nil`이면 역방향으로 오판한다. 기존 `voidReverts`에는 이 가드가 없었으나 `.statusChanged`는 항상 상태를 갖는다는 전제였다 — 감지기는 전제 없이 안전해야 한다.

**그 밖에는 원본 로직을 그대로 옮긴다.** 특히 "이미 짝지어진 이벤트는 건너뛴다" 같은 최적화를 넣지 않는다. 원본은 짝지어진 이벤트도 다음 순회에서 `later`로 다시 검사하며, 그 차이가 결과를 바꿀 수 있다. 기존 테스트가 통과하는 것이 이동이 맞았다는 유일한 증거다.

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter RevertDetectorTests`

Expected: PASS (6개)

- [ ] **Step 5: `AbuseGuard`가 감지기에 위임하게 한다**

`AbuseGuard.swift`의 `voidReverts`를 바꾼다.

```swift
    /// 전이 직후 창 안에서 정확히 역방향 전이가 관측되면 원래 지급분을 회수한다.
    ///
    /// 판정은 `RevertDetector`가 한다 — 시간축도 같은 판정을 써야 한 쌍을 두 층이
    /// 다르게 보지 않는다.
    private func voidReverts(_ events: inout [ScoredEvent]) {
        let reverted = RevertDetector.revertedIndices(
            in: events.map(\.event), windowMinutes: rules.revertWindowMinutes
        )
        for index in reverted { events[index].xp = 0 }
    }
```

`applyVoids`의 호출부도 함께 고친다 — `order` 인자가 더 이상 필요 없다.

```swift
        voidDuplicates(&working, order: order)
        voidReverts(&working)
```

`events.map(\.event)`가 만드는 배열은 `working`과 순서가 같으므로 인덱스가 그대로 맞는다.

- [ ] **Step 6: 기존 테스트가 무편집으로 통과하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`

Expected: **658 + 6 = 664개 통과.** 기존 테스트가 하나라도 깨지면 이동이 잘못된 것이다 — 테스트를 고치지 말고 멈추고 보고한다.

- [ ] **Step 7: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Rules/RevertDetector.swift \
        Packages/Jirarcade/Sources/ArcadeCore/Rules/AbuseGuard.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/RevertDetectorTests.swift
git commit -m "refactor: 되돌림 판정을 채점과 시간축이 함께 쓸 수 있게 꺼낸다"
```

---

### Task 2: 되돌아온 횟수를 센다

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Domain/StatusRevisits.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/StatusRevisitsTests.swift`

**Interfaces:**
- Consumes: `RevertDetector.revertedIndices(in:windowMinutes:)` (Task 1)
- Produces: `StatusRevisits.counts(from:revertWindowMinutes:) -> [String: Int]`

**세는 규칙 — 순서가 결과를 가른다:**

1. 되돌림 쌍의 두 이벤트는 건너뛴다.
2. 티켓별로 살아남은 `.statusChanged`를 `observedAt` 순으로 본다.
3. 첫 이벤트의 `fromStatus`로 집합을 연다.
4. 이벤트마다 **검사한 뒤에 넣는다.** `toStatus`가 이미 집합에 있으면 횟수를 1 올리고, 그다음 넣는다. 순서가 반대면 첫 이벤트조차 자기 자신 때문에 세어진다.
5. 돌아온 적 없는 티켓은 맵에 넣지 않는다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/ArcadeCoreTests/StatusRevisitsTests.swift`를 만든다.

```swift
import Testing
import Foundation
@testable import ArcadeCore

private func change(
    _ key: String, from: String, to: String, at: String
) -> DomainEvent {
    DomainEvent(issueKey: key, kind: .statusChanged, fromStatus: from, toStatus: to,
                observedAt: iso(at), actorAccountId: "acc-me")
}

/// 한 번도 돌아오지 않은 티켓은 맵에 없다. 0은 아무것도 말하지 않는다.
@Test func aTicketThatNeverReturnsIsAbsentFromTheMap() {
    let counts = StatusRevisits.counts(from: [
        change("DEMO-1", from: "대기", to: "진행 중", at: "2026-08-01T09:00:00Z"),
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-05T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "완료", at: "2026-08-09T09:00:00Z"),
    ], revertWindowMinutes: 10)

    #expect(counts["DEMO-1"] == nil)
}

/// 진행 중 → 검토 → 진행 중 → 검토 는 두 번 돌아온 것이다.
@Test func countsEachReturnToAStatusAlreadyVisited() {
    let counts = StatusRevisits.counts(from: [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-01T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-05T09:00:00Z"),
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-09T09:00:00Z"),
    ], revertWindowMinutes: 10)

    #expect(counts["DEMO-1"] == 2)
}

/// **오조작은 낙인이 아니다.** 창 안의 되돌림 쌍은 돌아온 것으로 세지 않는다.
@Test func aRevertInsideTheWindowDoesNotCountAsAReturn() {
    let counts = StatusRevisits.counts(from: [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-01T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-01T09:03:00Z"),
    ], revertWindowMinutes: 10)

    #expect(counts["DEMO-1"] == nil)
}

/// 창 밖의 복귀는 센다. 리뷰 반려로 돌아온 것은 진짜 움직임이다.
@Test func aReturnOutsideTheWindowCounts() {
    let counts = StatusRevisits.counts(from: [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-01T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-01T11:00:00Z"),
    ], revertWindowMinutes: 10)

    #expect(counts["DEMO-1"] == 1)
}

/// 티켓마다 따로 센다.
@Test func countsPerIssueIndependently() {
    let counts = StatusRevisits.counts(from: [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-01T09:00:00Z"),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-05T09:00:00Z"),
        change("DEMO-2", from: "대기", to: "진행 중", at: "2026-08-02T09:00:00Z"),
    ], revertWindowMinutes: 10)

    #expect(counts["DEMO-1"] == 1)
    #expect(counts["DEMO-2"] == nil)
}

/// 입력이 시간순이 아니어도 결과가 같다. 백필은 과거 이벤트를 나중에 넣는다.
@Test func doesNotTrustInputOrder() {
    let shuffled = [
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-05T09:00:00Z"),
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-01T09:00:00Z"),
    ]

    #expect(StatusRevisits.counts(from: shuffled, revertWindowMinutes: 10)["DEMO-1"] == 1)
}

/// 상태를 모르는 이벤트는 건너뛴다 — 거쳤는지 판정할 수 없다.
@Test func skipsEventsWithoutStatuses() {
    let counts = StatusRevisits.counts(from: [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-01T09:00:00Z"),
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: nil, toStatus: nil,
                    observedAt: iso("2026-08-03T09:00:00Z"), actorAccountId: nil),
        change("DEMO-1", from: "검토", to: "진행 중", at: "2026-08-05T09:00:00Z"),
    ], revertWindowMinutes: 10)

    #expect(counts["DEMO-1"] == 1)
}

/// 상태 변화가 아닌 이벤트는 세지 않는다.
@Test func ignoresNonStatusEvents() {
    let counts = StatusRevisits.counts(from: [
        change("DEMO-1", from: "진행 중", to: "검토", at: "2026-08-01T09:00:00Z"),
        DomainEvent(issueKey: "DEMO-1", kind: .touched, fromStatus: nil, toStatus: nil,
                    observedAt: iso("2026-08-03T09:00:00Z"), actorAccountId: nil),
    ], revertWindowMinutes: 10)

    #expect(counts["DEMO-1"] == nil)
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter StatusRevisitsTests`

Expected: FAIL — `StatusRevisits`가 없다.

- [ ] **Step 3: 구현한다**

`Sources/ArcadeCore/Domain/StatusRevisits.swift`:

```swift
import Foundation

/// 티켓이 **이미 거쳐 간 상태로 돌아온** 횟수.
///
/// 정체일은 마지막 상태 변화 이후를 센다. 그래서 3주 동안 진행 중 ↔ 검토를 오간 티켓도
/// 방금 옮겼다면 정체일이 0이다. 숫자 자체는 정직하지만 그것만 보면 공전 중이라는 사실이
/// 화면에서 사라진다. 이 값이 그 맥락을 되돌려준다.
///
/// **표시 전용이다.** 채점의 입력이 되지 않는다.
public enum StatusRevisits {
    public static func counts(
        from events: [DomainEvent],
        revertWindowMinutes: Double
    ) -> [String: Int] {
        // 오조작을 즉시 되돌린 흔적은 돌아온 것으로 세지 않는다 — 티켓은 어디에도 가지
        // 않았고, 세면 잘못 누른 것만으로 "왕복 중"이라는 낙인이 붙는다.
        let reverted = RevertDetector.revertedIndices(
            in: events, windowMinutes: revertWindowMinutes
        )

        // 입력 순서를 믿지 않는다 — 백필은 과거 이벤트를 나중에 넣는다.
        var byIssue: [String: [DomainEvent]] = [:]
        for index in events.indices.sorted(by: { events[$0].observedAt < events[$1].observedAt }) {
            guard reverted.contains(index) == false else { continue }
            let event = events[index]
            guard event.kind == .statusChanged,
                  event.fromStatus != nil, event.toStatus != nil
            else { continue }
            byIssue[event.issueKey, default: []].append(event)
        }

        var counts: [String: Int] = [:]
        for (key, ordered) in byIssue {
            guard let first = ordered.first, let opening = first.fromStatus else { continue }

            var visited: Set<String> = [opening]
            var returns = 0
            for event in ordered {
                guard let destination = event.toStatus else { continue }
                // **검사가 먼저다.** 넣고 검사하면 첫 이벤트조차 자기 자신 때문에 세어진다.
                if visited.contains(destination) { returns += 1 }
                visited.insert(destination)
            }
            if returns > 0 { counts[key] = returns }
        }
        return counts
    }
}
```

`events.indices`는 `Range<Int>`이고 `.sorted(by:)`가 `[Int]`를 돌려주므로 별도 확장이 필요 없다.

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter StatusRevisitsTests`

Expected: PASS (8개)

- [ ] **Step 5: 전체 테스트를 돌린다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`

Expected: 672개 통과. 기존 테스트는 하나도 바뀌지 않는다 — 이 태스크는 새 함수만 더한다.

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Domain/StatusRevisits.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/StatusRevisitsTests.swift
git commit -m "feat: 이미 거쳐 간 상태로 돌아온 횟수를 센다"
```

---

### Task 3: 시간축이 되돌림 쌍을 건너뛴다

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Domain/StatusTimeline.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Rules/ScoreEngine.swift` (`recompute`의 순회)
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/StatusTimelineTests.swift`

**Interfaces:**
- Consumes: `RevertDetector.revertedIndices(in:windowMinutes:)` (Task 1)
- Produces: `StatusTimeline.latestStatusEntry(from:revertWindowMinutes:) -> [String: Date]`

**이 태스크가 채점을 움직인다.** `statusEnteredAt`이 달라지면 `wakeXP`의 정체 배수가 달라진다. 의도된 변화다 — 되돌림 쌍이 기준선을 밀지 않으면 그 뒤의 전진 전이가 "3주 정체를 깬 것"으로 채점된다. 지금은 "방금 옮긴 것을 또 옮긴 것"으로 채점되어 배수가 1에 가깝다.

**기존 테스트가 깨지면 그것이 이 태스크의 산출물이다.** Task 1과 정반대다. 깨진 테스트가 되돌림 쌍이 기준선을 밀던 동작을 인코딩하고 있었다면 기대값을 새 동작으로 고친다. 다른 이유로 깨졌다면 멈추고 보고한다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/ArcadeCoreTests/StatusTimelineTests.swift`에 더한다. 파일이 없으면 만든다.

```swift
/// 잘못 눌러 즉시 되돌린 티켓은 정체일을 잃지 않는다.
///
/// 채점은 이미 그 쌍을 0점으로 만든다. 시간축이 같은 판정을 쓰지 않으면 한 쌍을 두 층이
/// 다르게 보게 되고, 그것이 "XP는 막혔는데 정체일은 리셋된다"는 증상이었다.
@Test func aRevertPairDoesNotMoveTheBaseline() {
    let events = [
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "대기", toStatus: "진행 중",
                    observedAt: iso("2026-08-01T09:00:00Z"), actorAccountId: "acc-me"),
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "진행 중", toStatus: "검토",
                    observedAt: iso("2026-08-20T09:00:00Z"), actorAccountId: "acc-me"),
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "검토", toStatus: "진행 중",
                    observedAt: iso("2026-08-20T09:03:00Z"), actorAccountId: "acc-me"),
    ]

    let map = StatusTimeline.latestStatusEntry(from: events, revertWindowMinutes: 10)

    #expect(map["DEMO-1"] == iso("2026-08-01T09:00:00Z"))
}

/// 창 밖의 복귀는 기준선을 민다. 리뷰 반려 후 재작업은 진짜 움직임이다.
@Test func aReturnOutsideTheWindowStillMovesTheBaseline() {
    let events = [
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "대기", toStatus: "진행 중",
                    observedAt: iso("2026-08-01T09:00:00Z"), actorAccountId: "acc-me"),
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "진행 중", toStatus: "검토",
                    observedAt: iso("2026-08-20T09:00:00Z"), actorAccountId: "acc-me"),
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "검토", toStatus: "진행 중",
                    observedAt: iso("2026-08-20T13:00:00Z"), actorAccountId: "acc-me"),
    ]

    let map = StatusTimeline.latestStatusEntry(from: events, revertWindowMinutes: 10)

    #expect(map["DEMO-1"] == iso("2026-08-20T13:00:00Z"))
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter StatusTimelineTests`

Expected: FAIL — 새 시그니처가 없어 컴파일되지 않는다.

- [ ] **Step 3: `StatusTimeline`을 고친다**

```swift
    /// 로그 전체를 반영한 **최종** 맵. 보드가 정체일을 계산할 때 쓴다.
    ///
    /// 되돌림 쌍은 제외한다 — 채점이 이미 0점으로 판정한 그 쌍을 시간축도 없던 일로 본다.
    /// 그러지 않으면 잘못 눌러 3초 만에 되돌린 티켓이 3주 정체를 잃는다.
    ///
    /// 입력 순서를 신뢰하지 않고 정렬한다 — `ArcadeStore.loadEvents()`의 순서는 계약이
    /// 아니고, 백필은 과거 이벤트를 나중에 넣는다. 동률은 순서가 뒤바뀌어도 같은 값을
    /// 쓰므로 타이브레이크가 필요 없다.
    public static func latestStatusEntry(
        from events: [DomainEvent],
        revertWindowMinutes: Double
    ) -> [String: Date] {
        let reverted = RevertDetector.revertedIndices(
            in: events, windowMinutes: revertWindowMinutes
        )
        var map: [String: Date] = [:]
        for index in events.indices.sorted(by: { events[$0].observedAt < events[$1].observedAt }) {
            guard reverted.contains(index) == false else { continue }
            apply(events[index], to: &map)
        }
        return map
    }
```

`apply(_:to:)`는 그대로 둔다 — 갱신 규칙의 유일한 정의라는 성질을 유지한다.

- [ ] **Step 4: `ScoreEngine.recompute`의 순회도 같은 제외를 거치게 한다**

`ScoreEngine.swift`의 `recompute`에서 `StatusTimeline.apply`를 부르는 순회를 찾는다(현재 약 79행). 그 순회 앞에서 되돌림 쌍을 구하고, 제외한 뒤 `apply`한다.

```swift
        // 시간축과 같은 판정을 쓴다 — 보드가 쓰는 최종값과 채점이 쓰는 시점별 값이
        // 다른 규칙으로 갈리면 같은 티켓의 정체일이 화면과 점수에서 달라진다.
        let revertedIndices = RevertDetector.revertedIndices(
            in: events, windowMinutes: rules.revertWindowMinutes
        )
```

그리고 순회 안에서 해당 인덱스를 건너뛴다. **순회가 인덱스를 갖고 있지 않다면** `for (index, event) in events.enumerated()` 형태로 바꾸되, 정렬 여부와 다른 로직을 건드리지 않도록 주의한다 — 이 순회는 `statusEnteredAt`만이 아니라 채점도 함께 한다.

**주의:** `recompute`가 받는 `events`가 이미 정렬돼 있는지 확인한다(`rg "sorted" Sources/ArcadeCore/Rules/ScoreEngine.swift`). 정렬 상태가 `RevertDetector`에 넘기는 배열과 같아야 인덱스가 맞는다.

- [ ] **Step 5: 전체 테스트를 돌리고 깨진 것을 판정한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`

깨진 테스트마다 **어떤 규칙을 인코딩하고 있었는지** 적는다. 되돌림 쌍이 기준선을 밀던 동작이면 기대값을 고친다. 그 밖의 이유면 멈추고 보고한다.

- [ ] **Step 6: 실제 로그에서 채점이 얼마나 움직이는지 잰다**

사용자의 실제 저장소를 읽어 되돌림 쌍이 몇 개인지 센다.

```bash
sqlite3 "$HOME/Library/Application Support/default.store" \
  "SELECT COUNT(*) FROM ZISSUEEVENTRECORD WHERE ZKINDRAW='statusChanged';"
```

되돌림 쌍의 개수는 SQL로 바로 셀 수 없으므로, 임시 테스트를 하나 써서 실제 이벤트를 읽어 `RevertDetector.revertedIndices`의 크기를 출력하고 **그 테스트는 커밋하지 않는다.** 어렵다면 이 단계를 "미측정"으로 보고하고 Task 7이 기록한다 — 추정치를 사실처럼 적지 않는다.

- [ ] **Step 7: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Domain/StatusTimeline.swift \
        Packages/Jirarcade/Sources/ArcadeCore/Rules/ScoreEngine.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/
git commit -m "fix: 되돌림 쌍이 정체 기준선을 밀지 않는다"
```

---

### Task 4: 왕복 횟수를 보드 슬롯까지 나른다

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Board/BoardLayout.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Board/LanePacker.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/BoardLayoutTests.swift`

**Interfaces:**
- Consumes: `StatusRevisits.counts` 결과 형태 `[String: Int]`
- Produces:
  - `BoardSlot.revisits: Int`
  - `BoardLayout.snapshot(issues:statusEnteredAt:statusRevisits:workflow:rules:minimumSpacing:now:calendar:)`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/ArcadeCoreTests/BoardLayoutTests.swift`에 더한다.

```swift
@Test func carriesTheRevisitCountOntoTheSlot() {
    let snapshot = BoardLayout.snapshot(
        issues: [issue(key: "DEMO-1", status: "In Progress")],
        statusEnteredAt: [:],
        statusRevisits: ["DEMO-1": 3],
        workflow: demoWorkflow, rules: .default,
        minimumSpacing: 0.1, now: iso("2026-08-25T09:00:00Z"), calendar: utc
    )

    let slot = snapshot.lanes.flatMap(\.slots).first { $0.issue.key == "DEMO-1" }
    #expect(slot?.revisits == 3)
}

/// 맵에 없는 티켓은 0이다. 돌아온 적 없다는 뜻이다.
@Test func aTicketAbsentFromTheRevisitMapGetsZero() {
    let snapshot = BoardLayout.snapshot(
        issues: [issue(key: "DEMO-1", status: "In Progress")],
        statusEnteredAt: [:],
        statusRevisits: [:],
        workflow: demoWorkflow, rules: .default,
        minimumSpacing: 0.1, now: iso("2026-08-25T09:00:00Z"), calendar: utc
    )

    let slot = snapshot.lanes.flatMap(\.slots).first { $0.issue.key == "DEMO-1" }
    #expect(slot?.revisits == 0)
}
```

**주의:** `snapshot.lanes.flatMap(\.slots)`가 실제 구조와 맞는지 기존 테스트에서 확인한다(`rg "snapshot\." Tests/ArcadeCoreTests/BoardLayoutTests.swift`). 다르면 기존 테스트가 쓰는 형태를 그대로 쓴다.

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter BoardLayoutTests`

Expected: FAIL — `statusRevisits` 인자와 `revisits` 속성이 없다.

- [ ] **Step 3: `BoardSlot`에 필드를 더한다**

`BoardLayout.swift`의 `BoardSlot`에 `sprintCarryOvers` 옆으로 더한다.

```swift
    /// 이미 거쳐 간 상태로 돌아온 횟수. **표시 전용이며 채점에 쓰지 않는다.**
    ///
    /// 정체일은 마지막 상태 변화 이후를 세므로, 오래 공전한 티켓도 방금 옮겼다면 0이다.
    /// 이 값이 그 맥락을 카드에 되돌려준다.
    public let revisits: Int
```

`init`의 인자 목록에도 `revisits: Int`를 더한다. **기본값을 주지 않는다** — 새 호출자가 빠뜨리면 컴파일이 막아야 한다.

- [ ] **Step 4: `snapshot`이 맵을 받아 슬롯에 싣게 한다**

`snapshot`의 시그니처에 `statusRevisits: [String: Int]`를 `statusEnteredAt` 다음에 더하고, 슬롯을 만들 때 `revisits: statusRevisits[issue.key] ?? 0`을 넘긴다.

`LanePacker`가 `BoardSlot`을 재생성하는 자리에도 `revisits: slot.revisits`를 전달한다(`rg "BoardSlot(" Sources/ArcadeCore/Board/`로 전부 찾는다).

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`

Expected: 전부 통과. 기존 `snapshot` 호출자(테스트 포함)가 새 인자를 받아야 컴파일된다 — 그 호출부에는 `statusRevisits: [:]`를 넘긴다.

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Board/ Packages/Jirarcade/Tests/ArcadeCoreTests/BoardLayoutTests.swift
git commit -m "feat: 왕복 횟수를 보드 슬롯까지 나른다"
```

---

### Task 5: `AppModel`이 왕복 횟수를 만들고 지운다

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/BoardStateTests.swift`

**Interfaces:**
- Consumes: `StatusRevisits.counts(from:revertWindowMinutes:)` (Task 2), `BoardLayout.snapshot(..., statusRevisits:)` (Task 4)
- Produces: `AppModel.statusRevisits: [String: Int]`

**어디를 고치나:** `AppModel`이 `statusEnteredAt`을 만드는 자리(현재 약 737행, `StatusTimeline.latestStatusEntry`)와 비우는 자리(현재 약 290행), 그리고 `boardSnapshot`이 `BoardLayout.snapshot`을 부르는 자리(현재 약 568행). 줄 번호는 바뀌었을 수 있으니 `rg "statusEnteredAt" Sources/ArcadeApp/AppModel.swift`로 전부 찾는다.

**Task 3이 `latestStatusEntry`의 시그니처를 바꿨다.** 그 호출부도 `revertWindowMinutes:`를 넘기도록 함께 고쳐야 컴파일된다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/ArcadeAppTests/BoardStateTests.swift`에 더한다.

```swift
/// 로그아웃은 계정별 상태를 전부 버린다. 왕복 횟수도 그중 하나다 — 남겨두면 다음 계정의
/// 같은 키를 가진 티켓 위에 남의 숫자가 그려진다.
@MainActor
@Test func signOutClearsTheRevisitCounts() async throws {
    let model = try makeModel()
    model.seedStatusRevisitsForTesting(["DEMO-1": 3])
    #expect(model.statusRevisits.isEmpty == false)

    await model.signOut()

    #expect(model.statusRevisits.isEmpty)
}
```

`seedStatusRevisitsForTesting`은 `seedIssuesForTesting`과 같은 자리에 같은 모양으로 만든다.

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test --filter signOutClearsTheRevisitCounts`

Expected: FAIL — 속성과 시딩 헬퍼가 없다.

- [ ] **Step 3: 상태를 더한다**

`statusEnteredAt` 선언 옆에:

```swift
    /// 티켓별 "이미 거쳐 간 상태로 돌아온" 횟수. 카드가 맥락을 그릴 때 쓴다.
    /// **표시 전용이며 채점에 쓰지 않는다.**
    public private(set) var statusRevisits: [String: Int] = [:]
```

테스트용 시딩은 `seedIssuesForTesting` 옆에:

```swift
    func seedStatusRevisitsForTesting(_ seeded: [String: Int]) {
        statusRevisits = seeded
    }
```

- [ ] **Step 4: 산출·전달·정리 세 자리를 고친다**

**산출** — `statusEnteredAt`을 만드는 줄 옆에:

```swift
        statusEnteredAt = StatusTimeline.latestStatusEntry(
            from: events, revertWindowMinutes: rules.revertWindowMinutes
        )
        // 로그를 두 번 돈다. 한 번으로 합칠 수 있으나 티켓 49건에 이벤트 5,900건
        // 규모에서 그 비용은 재보지 않고 최적화할 값이 아니다.
        statusRevisits = StatusRevisits.counts(
            from: events, revertWindowMinutes: rules.revertWindowMinutes
        )
```

`rules`를 그 자리에서 어떻게 얻는지 확인한다(`rg "rules" Sources/ArcadeApp/AppModel.swift | head`). 없으면 `RuleSet`을 갖고 있는 프로퍼티를 쓴다.

**전달** — `boardSnapshot`의 `BoardLayout.snapshot` 호출에 `statusRevisits: statusRevisits`를 더한다.

**정리** — `statusEnteredAt = [:]`이 있는 자리(로그아웃 정리)에 `statusRevisits = [:]`를 더한다.

- [ ] **Step 5: 전체 테스트를 돌린다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`

Expected: 전부 통과.

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift \
        Packages/Jirarcade/Tests/ArcadeAppTests/BoardStateTests.swift
git commit -m "feat: 왕복 횟수를 이벤트 로그에서 만들고 로그아웃이 지운다"
```

---

### Task 6: 카드에 `⇄N`을 그린다

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/TicketCardView.swift`

**Interfaces:**
- Consumes: `BoardSlot.revisits` (Task 4)
- Produces: 없음

**`ArcadeUI`에는 테스트 타깃이 없다.** 이 파일에는 판단을 두지 않는다 — 숫자를 읽어 그리는 것이 전부다.

**새 줄을 만들지 않는다.** 맨 윗줄은 `[등급] ─ Spacer ─ [정체일]`인 `HStack`이라 그 안에 넣으면 세로 공간을 쓰지 않는다. 카드는 이미 요약의 둘째 줄을 못 품는 예산이다.

- [ ] **Step 1: 맨 윗줄에 표시를 더한다**

`Text(stagnationLabel)` **앞에** 넣는다.

```swift
                // 새 줄을 만들지 않는다 — 카드는 이미 마감일과 이월이 함께 뜨면 요약이
                // 한 줄로 접히는 예산이다. 그리고 이 값이 수식하는 대상이 바로 옆의
                // 정체일이라, 같은 줄에 있어야 "이 18일은 3번 돌아온 뒤의 18일"로 읽힌다.
                if slot.revisits > 0 {
                    Text("⇄\(slot.revisits)")
                        .arcadeType(.readout, .xs)
                        .foregroundStyle(theme.inkTertiary)
                        .monospacedDigit()
                }
```

- [ ] **Step 2: 툴팁에 문장을 더한다**

카드의 `.help(...)`를 계산 프로퍼티로 뺀다.

```swift
        .help(cardTooltip)
```

그리고 아래에:

```swift
    /// 카드 툴팁. 왕복과 추정을 **둘 다** 말할 수 있어야 하므로 한 문장으로 고정하지 않는다.
    private var cardTooltip: String {
        var parts: [String] = []
        if slot.revisits > 0 {
            parts.append("이미 거쳐 간 상태로 \(slot.revisits)번 돌아왔습니다")
        }
        if slot.isApproximate {
            parts.append("관측 이력이 없어 마지막 갱신 시각으로 추정한 정체일입니다")
        }
        return parts.isEmpty ? slot.issue.summary : parts.joined(separator: "\n")
    }
```

**바뀌는 것:** 지금은 추정치이면 요약을 **대신** 보여준다. 이제는 왕복이나 추정이 있으면 그 문장(들)을, 둘 다 없으면 요약을 보여준다. 추정치인 티켓의 요약은 여전히 툴팁에 나오지 않는다 — 카드에 이미 요약이 있다.

- [ ] **Step 3: 빌드와 전체 테스트**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift build && swift test`

Expected: 빌드 성공, 전부 통과. 테스트 수는 그대로다 — `ArcadeUI`에는 테스트가 없다.

**`ModuleBoundaryTests`가 이 파일을 검사한다.** `.font(`나 `.system(size:`를 쓰면 실패한다. `arcadeType`만 쓴다.

- [ ] **Step 4: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/TicketCardView.swift
git commit -m "feat: 되돌아온 티켓을 카드의 정체일 옆에 표시한다"
```

---

### Task 7: 완성 정의 확인과 기록

**Files:**
- Modify: `docs/superpowers/records/2026-08-21-quest-board-visual-checklist.md`
- Modify: `docs/superpowers/specs/2026-08-25-status-revisit-design.md` (§6의 실측)

**Interfaces:**
- Consumes: 전체
- Produces: 없음

- [ ] **Step 1: 완성 정의를 코드와 대조한다**

스펙 §8의 항목을 하나씩 **실제 코드나 테스트로** 확인한다. 통과로 표시하는 항목마다 무엇을 읽었거나 돌렸는지 적는다. **확인할 수 없는 항목은 통과가 아니라 미확인으로 적는다.**

- [ ] **Step 2: 채점 불변을 확인한다**

```bash
cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade
swift test --filter "ScoreEngine|XpAwarder|Hygiene|AbuseGuard|EndToEnd"
rg "revisits|StatusRevisits" Sources/ArcadeCore/Rules/ Sources/ArcadeCore/Backfill/
```

`rg`는 `ScoreEngine.swift`의 `RevertDetector` 사용만 나와야 한다. `revisits`나 `StatusRevisits`가 채점 규칙에 나오면 안 된다.

- [ ] **Step 3: 채점이 실제로 얼마나 움직였는지 기록한다**

Task 3 Step 6에서 잰 값을 스펙 §6에 적는다. 재지 못했으면 **"미측정"이라고 적는다** — 추정치를 사실처럼 쓰지 않는다.

- [ ] **Step 4: 시각 검증 체크리스트에 항목을 더한다**

기존 절 구조와 문체에 맞춰 더한다. 전부 미체크로 둔다.

- 되돌아온 적 있는 티켓의 정체일 옆에 `⇄N`이 보인다
- 되돌아온 적 없는 티켓에는 아무것도 보이지 않는다
- 카드에 새 줄이 생기지 않았다 — 요약이 이전과 같은 줄 수로 보인다
- 카드에 마우스를 올리면 툴팁이 왕복 횟수를 말한다. 추정치인 티켓이면 두 문장이 함께 보인다
- **`⇄3`이 무슨 뜻인지 읽히는가** — 라벨이 없어 뜻을 모를 수 있다. 읽히지 않으면 정체일 라벨을 `18d⇄`로 바꾸거나 카드에서 빼고 상세 시트로 옮기는 대안이 있다

- [ ] **Step 5: 전체 테스트를 돌린다**

Run: `cd /Users/bahn/orca/workspaces/jirarcade/task-controlling/Packages/Jirarcade && swift test`

- [ ] **Step 6: 커밋**

```bash
git add docs/
git commit -m "docs: 되돌아온 티켓 표시의 완성 정의와 시각 검증 항목"
```

---

## 계획 자체 점검

**스펙 커버리지**

| 스펙 절 | 태스크 |
|---|---|
| §3.1 되돌림 감지 추출 | Task 1 |
| §3.2 왕복 횟수 계산 | Task 2 |
| §3.3 시간축이 쌍을 건너뜀 | Task 3 |
| §4.1 카드 표시 | Task 6 Step 1 |
| §4.2 툴팁 | Task 6 Step 2 |
| §4.3 표기 유보 | Task 7 Step 4 (시각 검증 항목) |
| §5 데이터 경로 | Task 4, Task 5 |
| §6 채점 불변과 간접 영향 | Task 3 Step 6, Task 7 Step 2·3 |
| §7 테스트 전략 | 각 태스크 |
| §8 완성 정의 | Task 7 |

**남는 위험**

- Task 3의 `ScoreEngine.recompute` 순회는 인덱스를 갖고 있지 않을 수 있다. 계획이 `enumerated()`로 바꾸라고 하되 정렬 상태를 확인하라고 지시한다 — 인덱스가 어긋나면 엉뚱한 이벤트를 건너뛴다. 이 태스크의 리뷰에서 가장 주의할 지점이다.
- Task 4는 `BoardSlot.init`에 기본값 없는 인자를 더하므로 모든 호출부가 깨진다. 컴파일러가 전부 잡아주지만 테스트 픽스처가 여럿일 수 있다.
- Task 1은 "동작이 바뀌면 안 되는 이동"인데 nil 가드 하나를 의도적으로 더한다. 그 하나를 제외하면 원본과 같아야 하며, 기존 `AbuseGuard` 테스트가 무편집 통과하는 것이 유일한 증거다.
