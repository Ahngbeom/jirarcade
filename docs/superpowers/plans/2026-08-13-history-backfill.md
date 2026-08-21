# 과거 이력 소급 (계획 2b-1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Jira changelog를 읽어 3년 8개월치 과거 상태 전이를 이벤트 로그에 소급 기록하고, 그 위에서 통산·시즌 두 레벨을 계산한다.

**Architecture:** `ChangelogParser`가 changelog JSON을 순수 함수로 `DomainEvent` 배열로 번역하고, `BackfillEngine`이 페이지네이션·재개·부분 실패를 관리하며 `ArcadeStore`에 append한다. 중복은 Jira가 준 `sourceHistoryId`로 막고, 관측 일수 오염은 `origin` 필드로 막는다. 채점은 기존 `ScoreEngine`을 그대로 쓰되 `since:` 파라미터로 시즌 범위를 잘라낸다.

**Tech Stack:** Swift 6.2 / Swift Testing / SwiftData (`VersionedSchema` 마이그레이션) / Jira REST v3 (`expand=changelog`, `/status`)

**Spec:** `docs/superpowers/specs/2026-08-13-history-backfill-design.md`

## Global Constraints

- 스펙이 최종 권위다. 계획과 충돌하면 스펙을 따르고 보고한다.
- 모듈 의존 방향은 단방향이다: `ArcadeUI → ArcadeApp → ArcadeCore → JiraKit`. 역방향 import 금지.
- `JiraKit`은 XP·레벨·정체 등 게임 개념 타입을 정의하거나 참조하지 않는다.
- 시간에 의존하는 모든 공개 함수는 `now: Date`를 파라미터로 받는다. 본문에서 `Date()` 호출 금지.
- `Calendar`는 주입받은 것만 쓴다. `Calendar.current` 직접 참조 금지.
- 규칙 상수는 전부 `RuleSet`에서 읽는다. 숫자 리터럴 금지.
- **이벤트 로그는 append-only다.** 갱신·삭제하는 코드를 작성하지 않는다.
- **`EventKind` 케이스는 추가만 한다. 개명·삭제 금지** — `loadEvents()`가 알 수 없는 rawValue를 버리므로 과거 이벤트가 영구 소실된다.
- **채점은 (이벤트 로그, RuleSet)만의 함수다.** 미러(`ObservedIssue`)에 의존하면 안 된다. 백필 이벤트도 `priorUpdatedAt`·`dueDateAtObservation`을 채워야 한다.
- 테스트는 Swift Testing(`@Test`/`#expect`). XCTest 금지.
- 뷰 코드에 색 리터럴 금지. 전부 `theme.*` 토큰으로 접근한다.
- **조직 데이터를 코드나 테스트에 남기지 않는다.** 실제 Jira 호스트·cloudId·사람 이름·accountId 금지. 상태명(`Merged to Staging`·`검수Done`)은 폴백 테스트의 핵심 입력이므로 유지한다.
- 각 태스크는 테스트 통과 후 커밋으로 끝난다. `git add .` / `git add -A` 금지 — 만진 파일만 명시적으로 add.

## File Structure

```
Sources/JiraKit/
├── ChangelogDTO.swift          (신규) changelog JSON 디코딩 + JiraStatusCatalogEntry
└── JiraClient.swift            (수정) searchIssuesWithChangelog / issueChangelog / statuses

Sources/ArcadeCore/
├── Domain/RuleSet.swift        (수정) awardsOnlyOwnTransitions, seasonDays
├── Domain/StatusCatalog.swift  (신규) 상태 ID → Stage 3단 폴백
├── Backfill/ChangelogParser.swift  (신규) changelog → [DomainEvent] (순수)
├── Backfill/BackfillEngine.swift   (신규) 페이지네이션·재개·부분 실패
├── Rules/XpAwarder.swift       (수정) actor 필터
├── Rules/ScoreEngine.swift     (수정) since 파라미터
├── Store/StoreModels.swift     (수정) sourceHistoryId·origin, BackfillRun 추가
└── Store/ArcadeStore.swift     (수정) 중복 방지 삽입, origin 필터, 백필 이력

Sources/ArcadeApp/
└── AppModel.swift              (수정) 백필 시작·중단·진행률, 시즌 요약

Sources/ArcadeUI/
├── ArcadeFloorView.swift       (수정) 진행 바, 시즌 XP 바
└── SettingsView.swift          (수정) "과거 기록 불러오기" 버튼
```

---

### Task 1: RuleSet에 백필 관련 규칙 추가

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Domain/RuleSet.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/RuleSetTests.swift`

**Interfaces:**
- Consumes: 기존 `RuleSet`
- Produces: `RuleSet.awardsOnlyOwnTransitions: Bool` (기본 `true`), `RuleSet.seasonDays: Int` (기본 `30`)

- [ ] **Step 1: 실패하는 테스트를 `RuleSetTests.swift` 끝에 추가**

```swift
/// 백필은 changelog의 author로 실행자를 알 수 있다. 남이 옮긴 전이를 내 XP로 세면
/// "내가 업무를 처리하는 행동을 유도한다"는 스펙의 목적과 어긋난다(스펙 §4.2).
@Test func defaultRuleSetAwardsOnlyOwnTransitions() {
    #expect(RuleSet.default.awardsOnlyOwnTransitions == true)
}

/// 시즌은 롤링 윈도우다. 길이를 RuleSet에 두어 사용자가 조정할 수 있게 한다(스펙 §6).
@Test func defaultSeasonIsThirtyDays() {
    #expect(RuleSet.default.seasonDays == 30)
}

/// 중단된 백필을 이어받는다. 처음부터 다시 훑으면 1,000여 건을 두 번 받고,
/// 중복 검사가 막아주더라도 왕복 시간이 통째로 낭비된다.
@MainActor
@Test func resumeContinuesFromTheSavedToken() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let runId = try store.beginBackfill(jql: "q", at: iso("2026-08-13T00:00:00Z"),
                                        totalIssueCount: 200)
    try store.advanceBackfill(runId, nextPageToken: "tok-2", processedIssueCount: 100,
                              discovered: [], partiallyRestored: [])

    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-2", historyId: "2",
                          at: iso("2023-03-01T00:00:00Z"), author: "acc-me")], nil),
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T01:00:00Z"),
                                       resume: true, progress: { _, _ in })

    #expect(source.requestedTokens == ["tok-2"], "저장된 지점부터 요청한다")
    #expect(outcome.processedIssues == 101, "이미 처리한 100건 위에 이어 센다")
}

/// 범위가 달라졌으면 이어받지 않는다 — 다른 JQL의 진행 지점은 이어붙일 수 없다.
@MainActor
@Test func resumeWithADifferentJqlStartsOver() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let runId = try store.beginBackfill(jql: "old", at: iso("2026-08-13T00:00:00Z"),
                                        totalIssueCount: 200)
    try store.advanceBackfill(runId, nextPageToken: "tok-2", processedIssueCount: 100,
                              discovered: [], partiallyRestored: [])

    let source = ScriptedChangelogSource(pages: [([], nil)])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)
    let outcome = try await engine.run(jql: "new", now: iso("2026-08-13T01:00:00Z"),
                                       resume: true, progress: { _, _ in })

    #expect(source.requestedTokens == [nil], "처음부터 시작한다")
    #expect(outcome.processedIssues == 0)
}

/// 페이지마다 진행 지점이 저장된다. 저장하지 않으면 중단 시 이어받을 곳이 없다.
@MainActor
@Test func progressIsPersistedEveryPage() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1",
                          at: iso("2023-02-01T00:00:00Z"), author: "acc-me")], "tok-2"),
        ([transitionIssue(key: "MPT-2", historyId: "2",
                          at: iso("2023-03-01T00:00:00Z"), author: "acc-me")], nil),
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)
    _ = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                             progress: { _, _ in })

    // 끝난 run은 재개 대상이 아니다 — 저장이 되긴 했는지는 실패 기록으로 본다.
    #expect(try store.resumableBackfill() == nil)
    #expect(try store.lastBackfillFailure() == nil)
}

/// 보충 조회도 페이지네이션된다. 한 번만 부르면 history가 100건을 넘는
/// 오래된 티켓이 보충 후에도 잘린 채 남는다.
@MainActor
@Test func supplementFetchesEveryChangelogPage() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let truncated = transitionIssue(key: "MPT-1", historyId: "1",
                                    at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                                    total: 3)
    let source = ScriptedChangelogSource(pages: [([truncated], nil)])
    source.supplementPages["MPT-1"] = [
        JiraChangelogPage(startAt: 0, maxResults: 2, total: 3, histories: [
            JiraChangelogHistory(id: "1", createdAt: iso("2023-02-01T00:00:00Z"),
                                 authorAccountId: "acc-me",
                                 items: [JiraChangelogItem(field: "status", fromId: "10009",
                                                           fromString: "To Do", toId: "10016",
                                                           toString: "In Progress")]),
            JiraChangelogHistory(id: "2", createdAt: iso("2023-02-02T00:00:00Z"),
                                 authorAccountId: "acc-me",
                                 items: [JiraChangelogItem(field: "status", fromId: "10016",
                                                           fromString: "In Progress", toId: "10020",
                                                           toString: "In Review")]),
        ]),
        JiraChangelogPage(startAt: 2, maxResults: 2, total: 3, histories: [
            JiraChangelogHistory(id: "3", createdAt: iso("2023-02-03T00:00:00Z"),
                                 authorAccountId: "acc-me",
                                 items: [JiraChangelogItem(field: "status", fromId: "10020",
                                                           fromString: "In Review", toId: "10011",
                                                           toString: "Done")]),
        ]),
    ]
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)
    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(source.supplementStartAts["MPT-1"] == [0, 2], "두 번째 페이지까지 받는다")
    #expect(outcome.insertedEvents == 3)
    #expect(outcome.partiallyRestored.isEmpty)
}

/// 카탈로그를 못 받으면 폴백 ②가 비활성인 채로 돈다. 그 사실이 결과에 드러나야
/// 사용자에게 "이번 백필은 정확도가 낮다"고 알릴 수 있다.
@MainActor
@Test func catalogFailureIsVisibleInTheOutcome() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1",
                          at: iso("2023-02-01T00:00:00Z"), author: "acc-me")], nil)
    ])
    source.catalogError = StubError()
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(outcome.catalogUnavailable)
    #expect(outcome.insertedEvents == 1, "카탈로그가 없어도 ①③으로 진행한다")
    #expect(outcome.resolvedFallbacks.isEmpty, "폴백 ②가 비활성이므로 실효 매핑도 없다")
}

/// 서버가 같은 페이지 토큰을 다시 주면 던진다. 그대로 두면 무한 루프이고,
/// 사용자에게는 앱이 멈춘 것으로 보인다.
@MainActor
@Test func repeatedPageTokenIsRejected() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([], "loop"), ([], "loop"),
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    await #expect(throws: BackfillError.repeatedPageToken) {
        _ = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                 progress: { _, _ in })
    }
}

/// 폴백으로 해석한 매핑이 결과에 담긴다 — 이게 있어야 채점에 연결할 수 있다(Task 10b).
@MainActor
@Test func resolvedFallbacksAreReturnedForScoring() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1",
                          at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                          fromId: "10016", from: "In Progress",
                          toId: "10071", to: "Merged to Staging")], nil)
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    // demoWorkflow에는 "Merged to Staging"이 없다. statusCategory가 indeterminate이므로
    // .active로 떨어지고, 그 매핑이 실효 맵에 실려 나가야 XP가 0이 되지 않는다.
    #expect(outcome.resolvedFallbacks == ["Merged to Staging": .active])
}

/// 총계를 모르면 nil을 그대로 넘긴다. 처리한 수를 총계로 삼으면 진행률이 늘 100%다.
@MainActor
@Test func progressPassesTheTotalThrough() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1",
                          at: iso("2023-02-01T00:00:00Z"), author: "acc-me")], "tok-2"),
        ([transitionIssue(key: "MPT-2", historyId: "2",
                          at: iso("2023-03-01T00:00:00Z"), author: "acc-me")], nil),
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    var reports: [(Int, Int?)] = []
    _ = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                             totalIssueCount: 1263,
                             progress: { done, total in reports.append((done, total)) })

    #expect(reports.map(\.0) == [1, 2])
    #expect(reports.allSatisfy { $0.1 == 1263 })
}

```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter "awardsOnlyOwnTransitions|SeasonIsThirty"`
Expected: FAIL — `value of type 'RuleSet' has no member 'awardsOnlyOwnTransitions'`

- [ ] **Step 3: `RuleSet`에 두 필드 추가**

기존 필드 선언부 끝(레벨 곡선 그룹 뒤)에 추가한다:

```swift
    // 백필과 시즌
    /// 내가 직접 옮긴 전이에만 XP를 준다. changelog의 author로 판별한다.
    /// false로 두면 담당 티켓의 모든 전이가 XP 대상이 된다(스펙 §4.2).
    public var awardsOnlyOwnTransitions: Bool
    /// 시즌 XP 바가 세는 기간(일). 고정 시즌이 아니라 `now - seasonDays`부터의
    /// 롤링 윈도우다 — 리셋 절벽을 만들지 않기 위해서다(스펙 §6).
    public var seasonDays: Int
```

`RuleSet.default` 리터럴에도 추가한다(`levelBase: 100, levelExponent: 1.8` 뒤):

```swift
        awardsOnlyOwnTransitions: true,
        seasonDays: 30
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS (기존 전부 + 신규 2)

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Domain/RuleSet.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/RuleSetTests.swift
git commit -m "feat: RuleSet에 awardsOnlyOwnTransitions와 seasonDays 추가"
```

---

### Task 2: XpAwarder에 실행자 필터

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Rules/XpAwarder.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/XpAwarderTests.swift`

**Interfaces:**
- Consumes: `RuleSet.awardsOnlyOwnTransitions` (Task 1)
- Produces: `XpAwarder.init(rules:workflow:myAccountId:calendar:)` — 기존 `init(rules:workflow:calendar:)`에 `myAccountId: String?`를 **`calendar` 앞에** 기본값 `nil`로 추가. `baseXP(for:issue:statusEnteredAt:now:)` 시그니처는 그대로.

- [ ] **Step 1: 실패하는 테스트를 `XpAwarderTests.swift` 끝에 추가**

```swift
/// 남이 옮긴 전이는 이벤트로 기록되지만 내 XP를 올리지 않는다(스펙 §4.2).
/// 기록까지 막지 않는 이유는 statusEnteredAt 때문이다 — 누가 옮겼든 정체 기준선은
/// 갱신돼야 하고, 그러지 않으면 정체일이 부풀어 보스전 XP가 과대 지급된다.
@Test func transitionsByOthersScoreZero() {
    let awarder = XpAwarder(rules: .default, workflow: demoWorkflow, myAccountId: "acc-me", calendar: utc)
    let event = DomainEvent(
        issueKey: "MPT-1", kind: .statusChanged,
        fromStatus: "To Do", toStatus: "In Progress",
        observedAt: iso("2026-08-12T00:00:00Z"), actorAccountId: "acc-someone-else",
        priorUpdatedAt: iso("2026-07-22T00:00:00Z")
    )
    #expect(awarder.baseXP(for: event, issue: nil, statusEnteredAt: nil,
                           now: iso("2026-08-12T00:00:00Z")) == 0)
}

@Test func transitionsByMeStillScore() {
    let awarder = XpAwarder(rules: .default, workflow: demoWorkflow, myAccountId: "acc-me", calendar: utc)
    let event = DomainEvent(
        issueKey: "MPT-1", kind: .statusChanged,
        fromStatus: "To Do", toStatus: "In Progress",
        observedAt: iso("2026-08-12T00:00:00Z"), actorAccountId: "acc-me",
        priorUpdatedAt: iso("2026-07-22T00:00:00Z")
    )
    #expect(awarder.baseXP(for: event, issue: nil, statusEnteredAt: nil,
                           now: iso("2026-08-12T00:00:00Z")) > 0)
}

/// myAccountId를 모르는 상황(로그인 전 재집계 등)에서는 필터를 적용하지 않는다.
/// 모른다는 이유로 전부 0점을 주면 과거 점수가 통째로 사라진다.
@Test func unknownIdentitySkipsTheActorFilter() {
    let awarder = XpAwarder(rules: .default, workflow: demoWorkflow, myAccountId: nil, calendar: utc)
    let event = DomainEvent(
        issueKey: "MPT-1", kind: .statusChanged,
        fromStatus: "To Do", toStatus: "In Progress",
        observedAt: iso("2026-08-12T00:00:00Z"), actorAccountId: "acc-anyone",
        priorUpdatedAt: iso("2026-07-22T00:00:00Z")
    )
    #expect(awarder.baseXP(for: event, issue: nil, statusEnteredAt: nil,
                           now: iso("2026-08-12T00:00:00Z")) > 0)
}

/// 플래그를 끄면 담당 티켓의 모든 전이가 다시 XP 대상이 된다.
@Test func disablingTheFlagRestoresScoringForOthers() {
    var rules = RuleSet.default
    rules.awardsOnlyOwnTransitions = false
    let awarder = XpAwarder(rules: rules, workflow: demoWorkflow, myAccountId: "acc-me", calendar: utc)
    let event = DomainEvent(
        issueKey: "MPT-1", kind: .statusChanged,
        fromStatus: "To Do", toStatus: "In Progress",
        observedAt: iso("2026-08-12T00:00:00Z"), actorAccountId: "acc-other",
        priorUpdatedAt: iso("2026-07-22T00:00:00Z")
    )
    #expect(awarder.baseXP(for: event, issue: nil, statusEnteredAt: nil,
                           now: iso("2026-08-12T00:00:00Z")) > 0)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter "transitionsByOthers|transitionsByMe|unknownIdentity|disablingTheFlag"`
Expected: FAIL — `extra argument 'myAccountId' in call`

- [ ] **Step 3: `XpAwarder`에 식별자와 필터 추가**

저장 프로퍼티와 이니셜라이저를 고친다:

```swift
    private let myAccountId: String?

    public init(rules: RuleSet, workflow: WorkflowMap, myAccountId: String? = nil) {
        self.rules = rules
        self.workflow = workflow
        self.myAccountId = myAccountId
        self.classifier = StagnationClassifier(rules: rules)
    }
```

`baseXP` 본문 맨 앞(switch 이전)에 필터를 넣는다:

```swift
        // 실행자 필터. 남이 옮긴 전이는 0점이다(스펙 §4.2).
        //
        // myAccountId가 nil이면 필터를 건너뛴다 — "내가 누군지 모른다"를 "전부 남이 했다"로
        // 해석하면 로그인 전 재집계에서 과거 점수가 통째로 사라진다. 모를 때는 관대한 쪽이 맞다.
        if rules.awardsOnlyOwnTransitions,
           let myAccountId,
           let actor = event.actorAccountId,
           actor != myAccountId {
            return 0
        }
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS. 기존 `XpAwarder` 호출부(`ScoreEngine`)는 기본값 `nil` 덕에 컴파일되고 동작이 바뀌지 않는다.

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Rules/XpAwarder.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/XpAwarderTests.swift
git commit -m "feat: XpAwarder에 실행자 필터 추가 (남이 옮긴 전이는 0점)"
```

---

### Task 3: ScoreEngine에 시즌 범위와 식별자 전달

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Rules/ScoreEngine.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/ScoreEngineTests.swift`

**Interfaces:**
- Consumes: `XpAwarder.init(rules:workflow:myAccountId:calendar:)` (Task 2), `RuleSet.seasonDays` (Task 1)
- Produces: `ScoreEngine.init(rules:workflow:calendar:myAccountId:)`, `recompute(events:issues:now:since:)` — `since: Date?` 기본값 `nil`

- [ ] **Step 1: 실패하는 테스트를 `ScoreEngineTests.swift` 끝에 추가**

```swift
/// 시즌은 이벤트 로그를 기간으로 자른 재집계일 뿐이다. 이벤트가 원본이고 점수가 파생이라
/// 필터 한 줄로 끝난다 — XP를 누적 저장했다면 "최근 30일 XP"를 따로 관리해야 했다(스펙 §6).
@MainActor
@Test func seasonScoreCountsOnlyRecentEvents() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utcCalendar,
                             myAccountId: "acc-me")
    let now = iso("2026-08-13T00:00:00Z")
    let events = [
        makeTransition(key: "MPT-1", at: iso("2026-01-01T00:00:00Z")),   // 시즌 밖
        makeTransition(key: "MPT-2", at: iso("2026-08-10T00:00:00Z")),   // 시즌 안
    ]

    let lifetime = engine.recompute(events: events, issues: [:], now: now)
    let season = engine.recompute(events: events, issues: [:], now: now,
                                  since: iso("2026-07-14T00:00:00Z"))

    #expect(season.summary.totalXP < lifetime.summary.totalXP)
    #expect(season.scored.count == 1)
    #expect(lifetime.scored.count == 2)
}

/// 경계에 정확히 걸린 이벤트는 시즌에 포함된다(>= since).
@MainActor
@Test func eventExactlyAtSeasonStartIsIncluded() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utcCalendar,
                             myAccountId: "acc-me")
    let boundary = iso("2026-07-14T00:00:00Z")
    let result = engine.recompute(
        events: [makeTransition(key: "MPT-1", at: boundary)],
        issues: [:], now: iso("2026-08-13T00:00:00Z"), since: boundary
    )
    #expect(result.scored.count == 1)
}

/// since를 주지 않으면 기존 동작과 완전히 같다 — 기존 호출부가 영향을 받지 않는다.
@MainActor
@Test func omittingSinceMatchesLifetime() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utcCalendar,
                             myAccountId: "acc-me")
    let now = iso("2026-08-13T00:00:00Z")
    let events = [makeTransition(key: "MPT-1", at: iso("2026-01-01T00:00:00Z"))]
    let a = engine.recompute(events: events, issues: [:], now: now)
    let b = engine.recompute(events: events, issues: [:], now: now, since: nil)
    #expect(a.summary == b.summary)
}
```

`ScoreEngineTests.swift` 상단에 헬퍼가 없으면 추가한다:

```swift
private var utcCalendar: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private func makeTransition(key: String, at when: Date) -> DomainEvent {
    DomainEvent(
        issueKey: key, kind: .statusChanged,
        fromStatus: "To Do", toStatus: "In Progress",
        observedAt: when, actorAccountId: "acc-me",
        priorUpdatedAt: when.addingTimeInterval(-days(21))
    )
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter "seasonScore|eventExactlyAtSeason|omittingSince"`
Expected: FAIL — `extra argument 'myAccountId' in call`

- [ ] **Step 3: `ScoreEngine`에 식별자와 `since` 추가**

이니셜라이저를 고친다:

```swift
    public init(rules: RuleSet, workflow: WorkflowMap, calendar: Calendar,
                myAccountId: String? = nil) {
        self.rules = rules
        self.workflow = workflow
        self.calendar = calendar
        self.awarder = XpAwarder(rules: rules, workflow: workflow, myAccountId: myAccountId,
                                 calendar: calendar)
        self.abuseGuard = AbuseGuard(rules: rules, calendar: calendar)
        self.curve = LevelCurve(rules: rules)
        self.streaks = StreakCalculator(rules: rules, calendar: calendar)
    }
```

`recompute`에 파라미터를 더하고, 정렬 직후 필터를 넣는다:

```swift
    /// - Parameter since: 이 시각 이후의 이벤트만 집계한다. nil이면 전체(통산).
    ///   시즌 XP 바가 이 파라미터로 계산된다(스펙 §6).
    ///
    ///   필터를 `ordered` 계산 **후**에 적용하는 이유: statusEnteredAt 재구성은 전체 이력을
    ///   봐야 정확한데, 잘라낸 뒤 계산하면 시즌 시작 이전의 전이를 못 봐서 정체일이 0으로
    ///   리셋된다. 그러면 같은 이벤트가 통산과 시즌에서 다른 XP를 받는다.
    public func recompute(
        events: [DomainEvent],
        issues: [String: ObservedIssue],
        now: Date,
        since: Date? = nil
    ) -> (scored: [ScoredEvent], summary: PlayerSummary) {
        let ordered = events.sorted { $0.observedAt < $1.observedAt }
```

기존 채점 루프는 `ordered` 전체를 돌되, `scored`에 담기 전에 범위를 검사한다. 루프 안 `scored.append(...)` 자리를 다음으로 바꾼다:

```swift
            if let since, event.observedAt < since {
                // 시즌 밖: statusEnteredAt 갱신에는 참여하되 점수에는 넣지 않는다.
                if event.kind == .statusChanged {
                    statusEnteredAt[event.issueKey] = event.observedAt
                }
                continue
            }
            scored.append(ScoredEvent(event: event, xp: xp))
```

> 주의: 기존 루프 끝의 `if event.kind == .statusChanged { statusEnteredAt[...] = ... }`는 그대로 둔다. 위 `continue` 분기가 그 갱신을 대신 수행하므로 시즌 밖 이벤트도 기준선을 남긴다.

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS. 재집계 멱등성 테스트가 여전히 통과해야 한다.

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Rules/ScoreEngine.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/ScoreEngineTests.swift
git commit -m "feat: ScoreEngine에 시즌 범위(since)와 실행자 식별 추가"
```

---

### Task 4: 이벤트 레코드에 출처 필드 추가

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Store/StoreModels.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Store/ArcadeStore.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/StoreTests.swift`

**Interfaces:**
- Consumes: 기존 `IssueEventRecord`
- Produces: `IssueEventRecord.sourceHistoryId: String?`, `IssueEventRecord.origin: String`, 상수 `EventOrigin.observed = "observed"` / `EventOrigin.backfill = "backfill"`

- [ ] **Step 1: 실패하는 테스트를 `StoreTests.swift` 끝에 추가**

```swift
/// 기존 이벤트는 전부 관측(diff)에서 왔다. 마이그레이션이 이 값을 채우지 않으면
/// 관측 일수 계산이 백필 이벤트와 구분되지 않는다(스펙 §3.1).
@MainActor
@Test func existingEventsDefaultToObservedOrigin() throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let when = iso("2026-08-13T09:00:00Z")
    try store.applySync(
        issues: [], events: [
            DomainEvent(issueKey: "MPT-1", kind: .statusChanged,
                        fromStatus: "To Do", toStatus: "In Progress",
                        observedAt: when, actorAccountId: "acc-me")
        ], observedAt: when
    )
    let records = try store.rawEventRecords()
    #expect(records.count == 1)
    #expect(records[0].origin == EventOrigin.observed)
    #expect(records[0].sourceHistoryId == nil)
}

@MainActor
@Test func originConstantsAreStable() {
    // rawValue 문자열이 저장되므로 바뀌면 과거 레코드의 의미가 달라진다.
    #expect(EventOrigin.observed == "observed")
    #expect(EventOrigin.backfill == "backfill")
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter "existingEventsDefault|originConstants"`
Expected: FAIL — `cannot find 'EventOrigin' in scope`

- [ ] **Step 3: `StoreModels.swift`에 상수와 필드 추가**

파일 상단(모델 선언 앞)에 상수를 둔다:

```swift
/// 이벤트의 출처. **문자열 값을 바꾸지 마라** — SwiftData에 그대로 저장되므로
/// 값이 바뀌면 이미 기록된 레코드의 의미가 달라진다.
public enum EventOrigin {
    public static let observed = "observed"
    public static let backfill = "backfill"
}
```

`IssueEventRecord`에 두 프로퍼티를 추가한다(`dueDateAtObservation` 뒤):

```swift
    /// Jira changelog history의 고유 id. 백필로 만든 이벤트만 값이 있다.
    /// 같은 전이를 두 번 기록하지 않기 위한 유일한 근거다 — 시각·상태명 비교로
    /// 추측하지 않는다(같은 초에 두 전이가 일어날 수 있고, 왕복 전이는 값이 같다).
    public var sourceHistoryId: String?
    /// `EventOrigin.observed` 또는 `EventOrigin.backfill`.
    /// 관측 일수는 observed만 세야 한다 — 백필이 3년 전 이벤트를 넣었다고
    /// 관측을 3년 했다고 말하면 거짓이다(스펙 §3.1).
    ///
    /// **기본값은 프로퍼티 선언에 붙어야 한다.** SwiftData가 기존 로우를 복원할 때
    /// 커스텀 `init`을 호출하지 않으므로, `init` 파라미터 기본값만으로는 이 컬럼이
    /// 없던 레코드를 열 수 없다.
    public var origin: String = EventOrigin.observed
```

이니셜라이저에 두 파라미터를 더한다. **기본값을 주어 기존 호출부가 깨지지 않게 한다**:

```swift
    public init(
        issueKey: String, kindRaw: String, fromStatus: String?, toStatus: String?,
        observedAt: Date, actorAccountId: String?, priorUpdatedAt: Date?,
        dueDateAtObservation: Date?,
        sourceHistoryId: String? = nil,
        origin: String = EventOrigin.observed
    ) {
```

본문 끝에 대입을 추가한다:

```swift
        self.sourceHistoryId = sourceHistoryId
        self.origin = origin
```

> SwiftData는 **옵셔널이거나 프로퍼티 선언에 기본값이 붙은** 프로퍼티 추가를 lightweight migration으로 처리한다. `sourceHistoryId`는 옵셔널이라 자동 충족이고, `origin`은 위처럼 **선언 자체에** `= EventOrigin.observed`를 붙여야 한다.
>
> **이니셜라이저 파라미터의 기본값으로는 부족하다.** SwiftData가 디스크의 기존 로우를 복원할 때는 커스텀 `init`을 호출하지 않고 자체 디코딩 경로를 쓰므로, `init`에만 있는 기본값은 참조되지 않는다. `@Model` 매크로는 프로퍼티 선언에 직접 붙은 리터럴만 스키마 기본값으로 읽는다.

- [ ] **Step 4: `ArcadeStore`에 검사용 접근자 추가**

`ArcadeStore.swift`의 이벤트 섹션에 추가한다:

```swift
    /// 테스트와 진단용. 값 타입으로 변환하기 전의 레코드를 그대로 준다.
    /// 프로덕션 코드는 `loadEvents()`를 쓴다.
    public func rawEventRecords() throws -> [IssueEventRecord] {
        try context.fetch(FetchDescriptor<IssueEventRecord>(
            sortBy: [SortDescriptor(\.observedAt, order: .forward)]
        ))
    }
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Store/StoreModels.swift \
        Packages/Jirarcade/Sources/ArcadeCore/Store/ArcadeStore.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/StoreTests.swift
git commit -m "feat: 이벤트 레코드에 sourceHistoryId와 origin 추가"
```

---

### Task 5: 중복 방지 삽입과 관측 일수 격리

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Store/ArcadeStore.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/StoreTests.swift`

**Interfaces:**
- Consumes: `EventOrigin`, `IssueEventRecord.sourceHistoryId` (Task 4)
- Produces: `ArcadeStore.appendBackfillEvents(_:historyIds:) throws -> Int` — 새로 삽입한 개수를 돌려준다. `observationDayCount(now:calendar:)`는 시그니처 그대로이나 `origin == observed`만 센다.

- [ ] **Step 1: 실패하는 테스트를 `StoreTests.swift` 끝에 추가**

```swift
/// 백필을 두 번 돌려도 이벤트가 중복되지 않는다. 재개 지점을 정확히 맞출 필요가 없어지는
/// 것이 이 검사의 진짜 이득이다 — 겹쳐 훑어도 안전하다(스펙 §7.2).
@MainActor
@Test func backfillEventsAreDeduplicatedByHistoryId() throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let event = DomainEvent(
        issueKey: "MPT-1", kind: .statusChanged, fromStatus: "To Do", toStatus: "In Progress",
        observedAt: iso("2023-03-02T12:13:52Z"), actorAccountId: "acc-me"
    )

    let first = try store.appendBackfillEvents([event], historyIds: ["50347"])
    let second = try store.appendBackfillEvents([event], historyIds: ["50347"])

    #expect(first == 1)
    #expect(second == 0, "같은 historyId는 다시 넣지 않는다")
    #expect(try store.loadEvents().count == 1)
}

/// 시각과 상태명이 같아도 historyId가 다르면 별개 전이다 — 왕복 전이가 그렇다.
@MainActor
@Test func differentHistoryIdsAreDistinctEvents() throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let when = iso("2023-03-02T12:13:52Z")
    let a = DomainEvent(issueKey: "MPT-1", kind: .statusChanged,
                        fromStatus: "To Do", toStatus: "In Progress",
                        observedAt: when, actorAccountId: "acc-me")
    let b = DomainEvent(issueKey: "MPT-1", kind: .statusChanged,
                        fromStatus: "In Progress", toStatus: "To Do",
                        observedAt: when, actorAccountId: "acc-me")

    _ = try store.appendBackfillEvents([a, b], historyIds: ["1", "2"])
    #expect(try store.loadEvents().count == 2)
}

/// 백필이 3년 전 이벤트를 넣어도 "관측 N일차"가 3년으로 뛰면 안 된다.
/// 그러면 정체 판정이 근사에서 정확으로 잘못 승격되고 UI도 거짓말을 한다(스펙 §3.1).
@MainActor
@Test func observationDayCountIgnoresBackfillEvents() throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let today = iso("2026-08-13T09:00:00Z")

    let run = try store.beginSyncRun(at: today)
    try store.finishSyncRun(run, at: today, issueCount: 1, failure: nil)

    _ = try store.appendBackfillEvents([
        DomainEvent(issueKey: "MPT-1", kind: .statusChanged,
                    fromStatus: "To Do", toStatus: "In Progress",
                    observedAt: iso("2023-01-01T00:00:00Z"), actorAccountId: "acc-me")
    ], historyIds: ["1"])

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    #expect(try store.observationDayCount(now: today, calendar: utc) == 1)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter "backfillEventsAreDedup|differentHistoryIds|observationDayCountIgnores"`
Expected: FAIL — `value of type 'ArcadeStore' has no member 'appendBackfillEvents'`

- [ ] **Step 3: `appendBackfillEvents` 구현**

`ArcadeStore.swift`의 이벤트 섹션에 추가한다:

```swift
    /// 백필 이벤트를 append한다. 이미 같은 `historyId`로 기록된 것은 건너뛰고,
    /// 새로 넣은 개수를 돌려준다.
    ///
    /// `events`와 `historyIds`는 같은 길이여야 하며 인덱스로 짝지어진다.
    /// 중복 판정을 시각·상태명이 아니라 Jira가 준 id로 하는 이유: 같은 초에 두 전이가
    /// 일어날 수 있고, 왕복 전이(A→B, B→A)는 되돌아왔을 때 값이 겹친다.
    public func appendBackfillEvents(
        _ events: [DomainEvent], historyIds: [String]
    ) throws -> Int {
        precondition(events.count == historyIds.count,
                     "events와 historyIds는 인덱스로 짝지어진다")
        guard !events.isEmpty else { return 0 }

        let existing = try context.fetch(FetchDescriptor<IssueEventRecord>(
            predicate: #Predicate { $0.sourceHistoryId != nil }
        ))
        var seen = Set(existing.compactMap(\.sourceHistoryId))

        var inserted = 0
        for (event, historyId) in zip(events, historyIds) {
            guard seen.insert(historyId).inserted else { continue }
            context.insert(IssueEventRecord(
                issueKey: event.issueKey, kindRaw: event.kind.rawValue,
                fromStatus: event.fromStatus, toStatus: event.toStatus,
                observedAt: event.observedAt, actorAccountId: event.actorAccountId,
                priorUpdatedAt: event.priorUpdatedAt,
                dueDateAtObservation: event.dueDateAtObservation,
                sourceHistoryId: historyId, origin: EventOrigin.backfill
            ))
            inserted += 1
        }
        try context.save()
        return inserted
    }
```

- [ ] **Step 4: `observationDayCount`가 관측 실행만 세는지 확인**

이 메서드는 `SyncRunRecord`를 세므로 백필 이벤트의 영향을 받지 않는다. 코드를 읽어 확인하고, 만약 이벤트를 세고 있다면 `SyncRunRecord` 기준으로 고친다. 확인 결과를 리포트에 적는다.

- [ ] **Step 5: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Store/ArcadeStore.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/StoreTests.swift
git commit -m "feat: historyId 기반 중복 방지 백필 삽입"
```

---

### Task 6: changelog DTO 디코딩

**Files:**
- Create: `Packages/Jirarcade/Sources/JiraKit/ChangelogDTO.swift`
- Create: `Packages/Jirarcade/Tests/JiraKitTests/ChangelogDecodingTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces: `JiraChangelogItem` (`field`, `fromString`, `toString`, `fromId`, `toId`), `JiraChangelogHistory` (`id`, `createdAt`, `authorAccountId`, `items`), `JiraChangelogPage` (`startAt`, `maxResults`, `total`, `histories`, `isTruncated`), `JiraIssueWithChangelog` (`key`, `createdAt`, `dueDate`, `changelog`), `JiraChangelogResponse.decodeSearch(_:) -> (issues: [JiraIssueWithChangelog], nextPageToken: String?)`, `JiraChangelogResponse.decodeIssueChangelog(_:) -> JiraChangelogPage`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/JiraKitTests/ChangelogDecodingTests.swift`:

```swift
import Testing
import Foundation
@testable import JiraKit

private let searchBody = """
{
  "issues": [{
    "key": "MPT-1647",
    "fields": {
      "created": "2022-12-30T10:05:20.812+0900",
      "duedate": "2023-03-10"
    },
    "changelog": {
      "startAt": 0, "maxResults": 10, "total": 2,
      "histories": [
        {
          "id": "50347",
          "created": "2023-02-28T10:15:06.939+0900",
          "author": { "accountId": "acc-me" },
          "items": [
            { "field": "status", "fieldId": "status",
              "from": "10009", "fromString": "To Do",
              "to": "10016", "toString": "In Progress" }
          ]
        },
        {
          "id": "50779",
          "created": "2023-03-02T12:13:52.874+0900",
          "author": { "accountId": "acc-other" },
          "items": [
            { "field": "description", "from": null, "fromString": "옛 본문",
              "to": null, "toString": "새 본문" },
            { "field": "status", "fieldId": "status",
              "from": "10016", "fromString": "In Progress",
              "to": "10071", "toString": "Merged to Staging" }
          ]
        }
      ]
    }
  }],
  "nextPageToken": "tok-2"
}
"""

@Test func decodesIssuesWithChangelog() throws {
    let (issues, token) = try JiraChangelogResponse.decodeSearch(Data(searchBody.utf8))
    #expect(token == "tok-2")
    #expect(issues.count == 1)

    let issue = issues[0]
    #expect(issue.key == "MPT-1647")
    #expect(issue.dueDate != nil)
    #expect(issue.changelog.histories.count == 2)
    #expect(issue.changelog.total == 2)
}

@Test func keepsAllItemsIncludingNonStatus() throws {
    // 걸러내는 일은 파서(ArcadeCore)가 한다. JiraKit은 응답을 있는 그대로 옮긴다.
    let (issues, _) = try JiraChangelogResponse.decodeSearch(Data(searchBody.utf8))
    let second = issues[0].changelog.histories[1]
    #expect(second.items.count == 2)
    #expect(second.items.map(\.field).contains("description"))
}

@Test func exposesStatusIdsForCategoryFallback() throws {
    let (issues, _) = try JiraChangelogResponse.decodeSearch(Data(searchBody.utf8))
    let statusItem = try #require(
        issues[0].changelog.histories[0].items.first { $0.field == "status" }
    )
    #expect(statusItem.fromId == "10009")
    #expect(statusItem.toId == "10016")
    #expect(statusItem.fromString == "To Do")
    #expect(statusItem.toString == "In Progress")
}

@Test func authorAccountIdIsCarried() throws {
    let (issues, _) = try JiraChangelogResponse.decodeSearch(Data(searchBody.utf8))
    #expect(issues[0].changelog.histories[0].authorAccountId == "acc-me")
    #expect(issues[0].changelog.histories[1].authorAccountId == "acc-other")
}

/// total이 histories보다 크면 서버가 잘라 보낸 것이다. 이 신호를 놓치면
/// history가 많은 오래된 티켓의 전이가 조용히 누락된다(스펙 §7.1).
@Test func truncationIsDetected() throws {
    let body = """
    { "issues": [{
        "key": "MPT-1", "fields": { "created": "2023-01-01T00:00:00.000+0900" },
        "changelog": { "startAt": 0, "maxResults": 10, "total": 42, "histories": [] }
    }] }
    """
    let (issues, _) = try JiraChangelogResponse.decodeSearch(Data(body.utf8))
    #expect(issues[0].changelog.isTruncated == true)
}

@Test func completeChangelogIsNotTruncated() throws {
    let (issues, _) = try JiraChangelogResponse.decodeSearch(Data(searchBody.utf8))
    #expect(issues[0].changelog.isTruncated == false)
}

/// 담당자가 없거나 마감일이 없는 티켓도 있다.
@Test func missingOptionalFieldsAreTolerated() throws {
    let body = """
    { "issues": [{
        "key": "MPT-2", "fields": { "created": "2023-01-01T00:00:00.000+0900" },
        "changelog": { "startAt": 0, "maxResults": 10, "total": 1, "histories": [
          { "id": "1", "created": "2023-01-02T00:00:00.000+0900", "items": [] }
        ] }
    }] }
    """
    let (issues, _) = try JiraChangelogResponse.decodeSearch(Data(body.utf8))
    #expect(issues[0].dueDate == nil)
    #expect(issues[0].changelog.histories[0].authorAccountId == nil)
}

/// 분수초가 **없는** 타임스탬프도 받아야 한다. 폴백 포매터가 실제로 실행되는 유일한
/// 테스트다 — 다른 fixture는 전부 분수초를 포함해서, 이 케이스가 없으면 폴백 분기가
/// 한 번도 실행되지 않은 채 "두 형식을 지원한다"고 믿게 된다.
@Test func decodesTimestampsWithoutFractionalSeconds() throws {
    let body = """
    { "issues": [{
        "key": "DEMO-1",
        "fields": { "created": "2023-01-01T00:00:00+0900" },
        "changelog": { "startAt": 0, "maxResults": 10, "total": 1, "histories": [
          { "id": "1", "created": "2023-02-01T09:00:00+0900",
            "items": [{ "field": "status", "from": "1", "fromString": "To Do",
                        "to": "2", "toString": "In Progress" }] }
        ] }
    }] }
    """
    let (issues, _) = try JiraChangelogResponse.decodeSearch(Data(body.utf8))
    // KST 09:00 = UTC 00:00. 절대 시각까지 확인해야 "파싱은 됐지만 값이 틀린" 경우를 잡는다.
    #expect(issues[0].changelog.histories[0].createdAt
            == ISO8601DateFormatter().date(from: "2023-02-01T00:00:00Z"))
}

/// 어느 형식으로도 읽을 수 없으면 **던진다.** 대체값을 넣으면 그 값이 그대로
/// `DomainEvent.observedAt`이 되어 정렬·정체일·statusEnteredAt 재구성을 오염시키는데,
/// 에러가 없으니 아무도 모른다. 티켓 하나가 실패하는 편이 3년치 로그가 틀리는 것보다 낫다.
@Test func unparsableTimestampThrowsRatherThanSubstituting() {
    let body = """
    { "issues": [{
        "key": "DEMO-1",
        "fields": { "created": "not-a-timestamp" },
        "changelog": { "startAt": 0, "maxResults": 10, "total": 0, "histories": [] }
    }] }
    """
    #expect(throws: (any Error).self) {
        _ = try JiraChangelogResponse.decodeSearch(Data(body.utf8))
    }
}

@Test func unparsableHistoryTimestampThrows() {
    let body = """
    { "issues": [{
        "key": "DEMO-1",
        "fields": { "created": "2023-01-01T00:00:00.000+0900" },
        "changelog": { "startAt": 0, "maxResults": 10, "total": 1, "histories": [
          { "id": "1", "created": "garbage", "items": [] }
        ] }
    }] }
    """
    #expect(throws: (any Error).self) {
        _ = try JiraChangelogResponse.decodeSearch(Data(body.utf8))
    }
}

@Test func decodesStandaloneIssueChangelog() throws {
    let body = """
    { "startAt": 0, "maxResults": 100, "total": 1, "values": [
        { "id": "99", "created": "2023-05-01T00:00:00.000+0900",
          "author": { "accountId": "acc-me" },
          "items": [{ "field": "status", "from": "1", "fromString": "A",
                      "to": "2", "toString": "B" }] }
    ] }
    """
    let page = try JiraChangelogResponse.decodeIssueChangelog(Data(body.utf8))
    #expect(page.histories.count == 1)
    #expect(page.histories[0].id == "99")
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter Changelog`
Expected: FAIL — `cannot find 'JiraChangelogResponse' in scope`

- [ ] **Step 3: DTO 구현**

`Sources/JiraKit/ChangelogDTO.swift`:

```swift
import Foundation

/// changelog history 안의 개별 변경 항목. 어떤 필드가 무엇에서 무엇으로 바뀌었는지.
public struct JiraChangelogItem: Sendable, Equatable {
    public let field: String
    public let fromId: String?
    public let fromString: String?
    public let toId: String?
    public let toString: String?
}

/// 한 번의 변경(한 사람이 한 시각에 저장한 묶음). 여러 필드가 함께 바뀔 수 있다.
public struct JiraChangelogHistory: Sendable, Equatable {
    public let id: String
    public let createdAt: Date
    public let authorAccountId: String?
    public let items: [JiraChangelogItem]
}

public struct JiraChangelogPage: Sendable, Equatable {
    public let startAt: Int
    public let maxResults: Int
    public let total: Int
    public let histories: [JiraChangelogHistory]

    /// 서버가 잘라 보냈는지. true면 `/issue/{key}/changelog`로 보충해야 한다.
    public var isTruncated: Bool { total > histories.count }
}

public struct JiraIssueWithChangelog: Sendable, Equatable {
    public let key: String
    public let createdAt: Date
    public let dueDate: Date?
    public let changelog: JiraChangelogPage
}

public enum JiraChangelogResponse {
    public static func decodeSearch(
        _ data: Data
    ) throws -> (issues: [JiraIssueWithChangelog], nextPageToken: String?) {
        let envelope = try JSONDecoder().decode(SearchEnvelope.self, from: data)
        return (try envelope.issues.map { try $0.model() }, envelope.nextPageToken)
    }

    public static func decodeIssueChangelog(_ data: Data) throws -> JiraChangelogPage {
        let raw = try JSONDecoder().decode(StandaloneEnvelope.self, from: data)
        return JiraChangelogPage(
            startAt: raw.startAt, maxResults: raw.maxResults, total: raw.total,
            histories: try raw.values.map { try $0.model() }
        )
    }

    // MARK: - 내부 디코딩 표현

    private struct SearchEnvelope: Decodable {
        let issues: [RawIssue]
        let nextPageToken: String?
    }

    private struct StandaloneEnvelope: Decodable {
        let startAt: Int
        let maxResults: Int
        let total: Int
        let values: [RawHistory]
    }

    private struct RawIssue: Decodable {
        let key: String
        let fields: Fields
        let changelog: RawChangelog

        struct Fields: Decodable {
            let created: String
            let duedate: String?
        }

        /// 시각을 파싱하지 못하면 **던진다.** `.distantPast` 같은 값으로 대체하면
        /// 그 값이 그대로 `DomainEvent.observedAt`이 되어 정렬에서 맨 앞으로 오고,
        /// 정체일을 천문학적으로 부풀리며, 그 티켓의 statusEnteredAt 재구성 전체를
        /// 오염시킨다 — 에러 하나 없이. 티켓 하나가 실패하는 편이 3년치 로그가
        /// 조용히 틀리는 것보다 낫다. 상위(BackfillEngine)가 그 티켓만 건너뛴다.
        func model() throws -> JiraIssueWithChangelog {
            guard let createdAt = JiraChangelogResponse.timestamp(fields.created) else {
                throw JiraError.decoding(context: "issue \(key): created=\(fields.created)")
            }
            return JiraIssueWithChangelog(
                key: key,
                createdAt: createdAt,
                dueDate: fields.duedate.flatMap(JiraChangelogResponse.dateOnly),
                changelog: try changelog.model()
            )
        }
    }

    private struct RawChangelog: Decodable {
        let startAt: Int
        let maxResults: Int
        let total: Int
        let histories: [RawHistory]

        func model() throws -> JiraChangelogPage {
            JiraChangelogPage(startAt: startAt, maxResults: maxResults, total: total,
                              histories: try histories.map { try $0.model() })
        }
    }

    private struct RawHistory: Decodable {
        let id: String
        let created: String
        let author: Author?
        let items: [RawItem]

        struct Author: Decodable { let accountId: String? }

        func model() throws -> JiraChangelogHistory {
            guard let createdAt = JiraChangelogResponse.timestamp(created) else {
                throw JiraError.decoding(context: "history \(id): created=\(created)")
            }
            return JiraChangelogHistory(
                id: id,
                createdAt: createdAt,
                authorAccountId: author?.accountId,
                items: items.map(\.model)
            )
        }
    }

    private struct RawItem: Decodable {
        let field: String
        let from: String?
        let fromString: String?
        let to: String?
        let toString: String?

        var model: JiraChangelogItem {
            JiraChangelogItem(field: field, fromId: from, fromString: fromString,
                              toId: to, toString: toString)
        }
    }

    // MARK: - 시각 파싱

    /// Jira는 `2023-02-28T10:15:06.939+0900` 형태를 보낸다. 소수점이 없는 변형도
    /// 받아들인다 — 하나만 지원하면 전량 파싱 실패로 이어질 수 있다.
    static func timestamp(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    static func dateOnly(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter Changelog`
Expected: PASS (9 tests)

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/JiraKit/ChangelogDTO.swift \
        Packages/Jirarcade/Tests/JiraKitTests/ChangelogDecodingTests.swift
git commit -m "feat: changelog 응답 디코딩과 잘림 감지"
```

---

### Task 7: JiraClient에 changelog·상태 목록 엔드포인트

**Files:**
- Modify: `Packages/Jirarcade/Sources/JiraKit/JiraClient.swift`
- Modify: `Packages/Jirarcade/Sources/JiraKit/ChangelogDTO.swift` (상태 카탈로그 DTO 추가)
- Test: `Packages/Jirarcade/Tests/JiraKitTests/ChangelogEndpointTests.swift`

**Interfaces:**
- Consumes: `JiraChangelogResponse` (Task 6), 기존 `perform(method:path:body:resource:)`
- Produces: `JiraClient.searchIssuesWithChangelog(jql:maxResults:pageToken:) async throws -> (issues: [JiraIssueWithChangelog], nextPageToken: String?)`, `JiraClient.issueChangelog(issueKey:startAt:) async throws -> JiraChangelogPage`, `JiraClient.statusCatalog() async throws -> [JiraStatusCatalogEntry]`, `JiraStatusCatalogEntry` (`id`, `name`, `categoryKey`)

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/JiraKitTests/ChangelogEndpointTests.swift`:

```swift
import Testing
import Foundation
@testable import JiraKit

private let auth = try! APITokenAuth(site: "example.atlassian.net", email: "u@e.com", token: "t")

@Test func searchWithChangelogRequestsTheExpandAndFields() async throws {
    let body = #"{"issues":[],"nextPageToken":null}"#
    let stub = StubHTTPClient(status: 200, body: body)
    let client = JiraClient(auth: auth, http: stub)

    _ = try await client.searchIssuesWithChangelog(
        jql: "assignee = currentUser()", maxResults: 100, pageToken: nil
    )

    let request = try #require(stub.sentRequests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString.hasSuffix("/search/jql") == true)

    let payload = try JSONSerialization.jsonObject(
        with: #require(request.httpBody)) as? [String: Any]
    #expect(payload?["jql"] as? String == "assignee = currentUser()")
    #expect(payload?["maxResults"] as? Int == 100)
    // 배열이 아니라 문자열이어야 한다. 배열로 보내면 백필이 changelog를 한 건도 못 받는다.
    #expect(payload?["expand"] as? String == "changelog")
    // created와 duedate가 없으면 priorUpdatedAt/dueDateAtObservation을 복원할 수 없다.
    let fields = payload?["fields"] as? [String]
    #expect(fields?.contains("created") == true)
    #expect(fields?.contains("duedate") == true)
}

@Test func pageTokenIsForwarded() async throws {
    let stub = StubHTTPClient(status: 200, body: #"{"issues":[]}"#)
    let client = JiraClient(auth: auth, http: stub)
    _ = try await client.searchIssuesWithChangelog(jql: "q", maxResults: 100, pageToken: "tok-9")

    let payload = try JSONSerialization.jsonObject(
        with: #require(stub.sentRequests.first?.httpBody)) as? [String: Any]
    #expect(payload?["nextPageToken"] as? String == "tok-9")
}

@Test func issueChangelogUsesStartAt() async throws {
    let body = #"{"startAt":10,"maxResults":100,"total":12,"values":[]}"#
    let stub = StubHTTPClient(status: 200, body: body)
    let client = JiraClient(auth: auth, http: stub)

    let page = try await client.issueChangelog(issueKey: "MPT-1", startAt: 10)

    // URLComponents로 파싱해 경로와 쿼리를 분리해서 본다. absoluteString.contains로
    // 보면 안 된다 — `?`가 `%3F`로 이스케이프돼 쿼리가 경로에 처박힌 URL도
    // contains("startAt=10")을 통과한다(실제로 그렇게 통과하는 걸 확인했다).
    let sent = try #require(stub.sentRequests.first?.url)
    let components = try #require(URLComponents(url: sent, resolvingAgainstBaseURL: false))
    #expect(components.path.hasSuffix("/issue/MPT-1/changelog"))
    #expect(components.queryItems?.first { $0.name == "startAt" }?.value == "10")
    #expect(components.queryItems?.first { $0.name == "maxResults" }?.value == "100")
    #expect(page.startAt == 10)
}

@Test func statusCatalogDecodesCategories() async throws {
    let body = """
    [
      { "id": "10009", "name": "To Do", "statusCategory": { "key": "new" } },
      { "id": "10016", "name": "In Progress", "statusCategory": { "key": "indeterminate" } },
      { "id": "10011", "name": "Done", "statusCategory": { "key": "done" } }
    ]
    """
    let stub = StubHTTPClient(status: 200, body: body)
    let client = JiraClient(auth: auth, http: stub)

    let catalog = try await client.statusCatalog()

    // #expect는 실패해도 멈추지 않는다. count가 어긋난 상태에서 catalog[0]을 쓰면
    // 테스트 실패가 아니라 인덱스 범위 초과로 프로세스가 죽는다 — try #require로 꺼낸다.
    #expect(catalog.count == 3)
    let first = try #require(catalog.first)
    #expect(first.id == "10009")
    #expect(first.name == "To Do")
    #expect(first.categoryKey == "new")
    #expect(try #require(catalog.dropFirst().first).categoryKey == "indeterminate")

    let path = try #require(URLComponents(
        url: #require(stub.sentRequests.first?.url), resolvingAgainstBaseURL: false)).path
    #expect(path.hasSuffix("/status"))
}

@Test func changelogSearchMapsUnauthorized() async {
    let client = JiraClient(auth: auth, http: StubHTTPClient(status: 401))
    await #expect(throws: JiraError.unauthorized) {
        _ = try await client.searchIssuesWithChangelog(jql: "q", maxResults: 100, pageToken: nil)
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter "searchWithChangelog|pageTokenIsForwarded|issueChangelogUses|statusCatalog|changelogSearchMaps"`
Expected: FAIL — `value of type 'JiraClient' has no member 'searchIssuesWithChangelog'`

- [ ] **Step 3: 상태 카탈로그 DTO를 `ChangelogDTO.swift`에 추가**

```swift
/// `/rest/api/3/status`의 항목. 워크플로에서 빠진 과거 상태도 여기 남아 있어,
/// 매핑되지 않은 상태를 statusCategory로 폴백할 수 있다(스펙 §5).
public struct JiraStatusCatalogEntry: Sendable, Equatable, Decodable {
    public let id: String
    public let name: String
    /// `new` / `indeterminate` / `done`. Jira의 3분류 키다.
    public let categoryKey: String

    private enum CodingKeys: String, CodingKey { case id, name, statusCategory }
    private struct Category: Decodable { let key: String }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        categoryKey = try container.decode(Category.self, forKey: .statusCategory).key
    }

    public init(id: String, name: String, categoryKey: String) {
        self.id = id
        self.name = name
        self.categoryKey = categoryKey
    }
}
```

- [ ] **Step 4: `JiraClient`에 세 메서드 추가**

`cloudId(forSite:)` 뒤에 넣는다:

```swift
    /// changelog를 함께 받는 검색. 백필의 주 경로다.
    ///
    /// `created`와 `duedate`를 fields에 넣는 이유: 백필 이벤트도 `priorUpdatedAt`과
    /// `dueDateAtObservation`을 채워야 하는데(스펙 §4.3), 첫 history 이전의 기준선은
    /// 티켓 생성 시각이고 마감일은 변경 이력이 없을 때 현재 값을 써야 한다.
    public func searchIssuesWithChangelog(
        jql: String, maxResults: Int, pageToken: String?
    ) async throws -> (issues: [JiraIssueWithChangelog], nextPageToken: String?) {
        var payload: [String: Any] = [
            "jql": jql,
            "maxResults": maxResults,
            "fields": ["created", "duedate"],
            // 이 엔드포인트에서만 expand가 배열이 아니라 **콤마 구분 문자열**이다.
            // Atlassian 문서가 명시적으로 경고한다: "unlike the majority of instances
            // where expand is specified, expand is defined as a comma-delimited string".
            // 구버전 POST /search는 배열이라 혼동하기 쉽다. 배열로 보내면 400이거나
            // 무시되고, 어느 쪽이든 changelog가 안 와서 백필 이벤트가 0건이 된다.
            "expand": "changelog",
        ]
        if let pageToken { payload["nextPageToken"] = pageToken }

        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await perform(method: "POST", path: "/search/jql",
                                     body: body, resource: "search")
        do {
            return try JiraChangelogResponse.decodeSearch(data)
        } catch {
            throw JiraError.decoding(context: "searchIssuesWithChangelog")
        }
    }

    /// 티켓 하나의 changelog. 검색 응답이 잘렸을 때(`isTruncated`) 보충용이다.
    public func issueChangelog(
        issueKey: String, startAt: Int
    ) async throws -> JiraChangelogPage {
        let data = try await perform(
            method: "GET",
            path: "/issue/\(issueKey)/changelog",
            body: nil, resource: issueKey,
            query: [
                URLQueryItem(name: "startAt", value: String(startAt)),
                URLQueryItem(name: "maxResults", value: "100"),
            ]
        )
        do {
            return try JiraChangelogResponse.decodeIssueChangelog(data)
        } catch {
            throw JiraError.decoding(context: "issueChangelog(\(issueKey))")
        }
    }

    /// 사이트의 모든 상태와 그 statusCategory. 백필 시작 시 한 번 받아 캐시한다.
    public func statusCatalog() async throws -> [JiraStatusCatalogEntry] {
        let data = try await perform(method: "GET", path: "/status",
                                     body: nil, resource: "status")
        do {
            return try JSONDecoder().decode([JiraStatusCatalogEntry].self, from: data)
        } catch {
            throw JiraError.decoding(context: "statusCatalog")
        }
    }
```

- [ ] **Step 4b: `perform`에 쿼리 파라미터 지원 추가**

`path`에 `?startAt=10`을 그냥 붙이면 **동작하지 않는다.** `URL.appendingPathComponent`는
`?`를 경로 문자로 보고 `%3F`로 이스케이프한다. 실측:

```
https://x.atlassian.net/rest/api/3/issue/MPT-1/changelog%3FstartAt=10&maxResults=100
```

Jira는 이걸 경로로 해석해 404를 낸다. `JiraClient`가 쿼리스트링이 필요한 엔드포인트를
만난 건 이번이 처음이라 지금까지 드러나지 않았다.

`JiraClient.swift`의 `perform` **두 오버로드 모두**에 `query`를 추가한다:

```swift
    private func perform(
        method: String, path: String, body: Data?, resource: String,
        query: [URLQueryItem] = []
    ) async throws -> Data {
        try await perform(method: method, path: path, body: body,
                          resource: resource, query: query, allowingRetry: true)
    }

    private func perform(
        method: String, path: String, body: Data?, resource: String,
        query: [URLQueryItem] = [], allowingRetry: Bool
    ) async throws -> Data {
        // 쿼리는 URLComponents로 붙인다. path에 "?..."를 이어 붙이면
        // appendingPathComponent가 `?`를 %3F로 이스케이프해 경로의 일부가 된다.
        var components = URLComponents(
            url: auth.baseURL.appendingPathComponent(path.dropFirstSlash),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw JiraError.invalidSite }

        var request = URLRequest(url: url)
        // ... 이하 기존 본문 그대로 ...
```

재시도 경로(401 복구)에서도 `query:`를 함께 넘겨야 한다 — 빠뜨리면 재시도가
쿼리 없는 URL로 나간다:

```swift
                return try await perform(method: method, path: path, body: body,
                                         resource: resource, query: query,
                                         allowingRetry: false)
```

기존 호출부(`myself`/`searchIssues`/`transitions`/`performTransition`)는 기본값
`query: []`가 적용되므로 **고칠 필요가 없다.** `components?.queryItems`를
빈 배열이 아닐 때만 넣는 이유가 이것이다 — 빈 배열을 넣으면 URL 끝에 `?`가 붙어
기존 요청의 URL이 바뀐다.

- [ ] **Step 5: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/JiraKit/JiraClient.swift \
        Packages/Jirarcade/Sources/JiraKit/ChangelogDTO.swift \
        Packages/Jirarcade/Tests/JiraKitTests/ChangelogEndpointTests.swift
git commit -m "feat: changelog 검색·보충 조회·상태 카탈로그 엔드포인트"
```

---

### Task 8: StatusCatalog — 3단 워크플로 폴백

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Domain/StatusCatalog.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/StatusCatalogTests.swift`

**Interfaces:**
- Consumes: `WorkflowMap` (기존), `JiraStatusCatalogEntry` (Task 7)
- Produces: `StatusCatalog.init(workflow:entries:)`, `StatusCatalog.stage(forId:name:) -> StageResolution`, `enum StageResolution { case mapped(Stage), fallback(Stage), unmapped(String) }`, `StatusCatalog.unmappedNames: Set<String>`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/ArcadeCoreTests/StatusCatalogTests.swift`:

```swift
import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

private let entries = [
    JiraStatusCatalogEntry(id: "10009", name: "To Do", categoryKey: "new"),
    JiraStatusCatalogEntry(id: "10016", name: "In Progress", categoryKey: "indeterminate"),
    JiraStatusCatalogEntry(id: "10071", name: "Merged to Staging", categoryKey: "indeterminate"),
    JiraStatusCatalogEntry(id: "10013", name: "검수Done", categoryKey: "indeterminate"),
    JiraStatusCatalogEntry(id: "10011", name: "Done", categoryKey: "done"),
]

/// ① 현재 워크플로 매핑이 최우선이다.
@Test func mappedStatusWinsOverFallback() {
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: entries)
    #expect(catalog.stage(forId: "10016", name: "In Progress") == .mapped(.active))
}

/// ② 매핑에 없으면 statusCategory로 떨어뜨린다. 0점으로 버리는 것보다 방향이 맞다(스펙 §5).
@Test func unmappedStatusFallsBackToCategory() {
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: entries)
    #expect(catalog.stage(forId: "10071", name: "Merged to Staging") == .fallback(.active))

    // 이름에 "Done"이 들어가지만 statusCategory는 indeterminate다. 이름으로 단계를
    // 추측하면 틀리고 카테고리로 봐야 맞는 케이스 — 폴백이 이름이 아니라 ID로 찾은
    // 엔트리의 카테고리를 쓰는 이유다.
    #expect(catalog.stage(forId: "10013", name: "검수Done") == .fallback(.active))

    // demoWorkflow에 있는 이름은 카탈로그에 있어도 ①이 먼저 잡는다.
    #expect(catalog.stage(forId: "10009", name: "To Do") == .mapped(.backlog))
    #expect(catalog.stage(forId: "10011", name: "Done") == .mapped(.done))
}

/// ③ 카탈로그에도 없으면 미매핑이다. 임의 단계로 추측하지 않는다.
@Test func unknownStatusIsUnmapped() {
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: entries)
    #expect(catalog.stage(forId: "99999", name: "사라진상태") == .unmapped("사라진상태"))
}

/// 카탈로그 조회는 ID로 한다. 상태 이름이 바뀌어도 과거 changelog의 이름으로
/// 조회했을 때 여전히 찾아진다.
@Test func catalogLookupSurvivesARename() {
    let renamed = [JiraStatusCatalogEntry(id: "10071", name: "Staged", categoryKey: "indeterminate")]
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: renamed)
    // changelog에는 옛 이름이 박혀 있지만 ID는 그대로다.
    #expect(catalog.stage(forId: "10071", name: "Merged to Staging") == .fallback(.active))
}

/// 폴백으로 처리한 상태를 모아둔다 — 백필이 끝나면 매핑 마법사 후보가 된다(스펙 §5).
@Test func fallbackAndUnmappedNamesAreCollected() {
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: entries)
    _ = catalog.stage(forId: "10071", name: "Merged to Staging")
    _ = catalog.stage(forId: "99999", name: "사라진상태")
    _ = catalog.stage(forId: "10016", name: "In Progress")   // 매핑됨 — 수집 대상 아님

    #expect(catalog.unmappedNames.contains("Merged to Staging"))
    #expect(catalog.unmappedNames.contains("사라진상태"))
    #expect(!catalog.unmappedNames.contains("In Progress"))
}

/// 이름도 ID도 없는 status 변경이 마법사 후보에 빈 항목을 만들면 안 된다.
/// changelog의 toString이 비어 오는 경우가 실제로 있다.
@Test func namelessStatusIsNotCollected() {
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: entries)
    #expect(catalog.stage(forId: nil, name: nil) == .unmapped(""))
    #expect(catalog.unmappedNames.isEmpty)
}

/// 카탈로그 조회에 실패해 entries가 비어도 ①③만으로 degraded 동작해야 한다(스펙 §8).
@Test func emptyCatalogStillUsesTheWorkflowMap() {
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: [])
    #expect(catalog.stage(forId: "10016", name: "In Progress") == .mapped(.active))
    #expect(catalog.stage(forId: "10071", name: "Merged to Staging") == .unmapped("Merged to Staging"))
}

@Test(arguments: [("new", Stage.backlog), ("indeterminate", Stage.active), ("done", Stage.done)])
func categoryKeysMapToStages(key: String, expected: Stage) {
    let catalog = StatusCatalog(
        workflow: WorkflowMap(statusToStage: [:]),
        entries: [JiraStatusCatalogEntry(id: "1", name: "X", categoryKey: key)]
    )
    #expect(catalog.stage(forId: "1", name: "X") == .fallback(expected))
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter StatusCatalog`
Expected: FAIL — `cannot find 'StatusCatalog' in scope`

- [ ] **Step 3: 구현**

`Sources/ArcadeCore/Domain/StatusCatalog.swift`:

```swift
import Foundation
import JiraKit

/// 상태 하나를 단계로 해석한 결과. 어떤 경로로 결정됐는지 구분해 UI가 정확도를 표시할 수 있다.
public enum StageResolution: Sendable, Equatable {
    /// ① 현재 워크플로 매핑에 있었다. 정확하다.
    case mapped(Stage)
    /// ② statusCategory로 떨어뜨렸다. 방향은 맞지만 세분화가 없다.
    case fallback(Stage)
    /// ③ 어느 쪽에도 없다. XP 0이며 매핑 마법사 후보가 된다.
    case unmapped(String)

    /// 채점에 쓸 단계. 미매핑이면 nil이다.
    public var stage: Stage? {
        switch self {
        case .mapped(let s), .fallback(let s): s
        case .unmapped: nil
        }
    }
}

/// 3단 폴백으로 상태를 단계에 매핑한다(스펙 §5).
///
/// 과거 워크플로가 개편되면 changelog에는 현재 매핑에 없는 상태명이 대량 등장한다.
/// 그걸 전부 0점 처리하면 소급의 상당 부분이 사라지므로, Jira가 모든 상태에 붙이는
/// statusCategory(new/indeterminate/done)로 떨어뜨린다.
public final class StatusCatalog: @unchecked Sendable {
    private let workflow: WorkflowMap
    private let byId: [String: JiraStatusCatalogEntry]
    private let lock = NSLock()
    private var collected: Set<String> = []

    public init(workflow: WorkflowMap, entries: [JiraStatusCatalogEntry]) {
        self.workflow = workflow
        self.byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 폴백·미매핑으로 처리된 상태명. 백필이 끝나면 매핑 마법사 후보가 된다.
    public var unmappedNames: Set<String> {
        lock.withLock { collected }
    }

    public func stage(forId id: String?, name: String?) -> StageResolution {
        let label = name ?? id ?? ""

        // ① 현재 매핑
        if let name, let mapped = workflow.stage(for: name) {
            return .mapped(mapped)
        }

        // ② statusCategory 폴백. 이름은 바뀔 수 있으므로 ID로 찾는다.
        if let id, let entry = byId[id], let stage = Self.stage(forCategory: entry.categoryKey) {
            collect(label)
            return .fallback(stage)
        }

        // ③ 미매핑
        collect(label)
        return .unmapped(label)
    }

    /// 빈 라벨은 수집하지 않는다 — 마법사에 이름 없는 항목이 뜨면 사용자가
    /// 무엇을 매핑하는지 알 수 없다. 해석 결과(.unmapped(""))는 그대로 돌려주되
    /// 후보 목록에만 넣지 않는다.
    private func collect(_ label: String) {
        guard !label.isEmpty else { return }
        lock.withLock { _ = collected.insert(label) }
    }

    private static func stage(forCategory key: String) -> Stage? {
        switch key {
        case "new": .backlog
        case "indeterminate": .active
        case "done": .done
        default: nil
        }
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter StatusCatalog`
Expected: PASS (10 tests — 파라미터화 3건 포함)

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Domain/StatusCatalog.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/StatusCatalogTests.swift
git commit -m "feat: 3단 워크플로 폴백 (매핑 → statusCategory → 미매핑)"
```

---

### Task 9: ChangelogParser — changelog를 이벤트로

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Backfill/ChangelogParser.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/ChangelogParserTests.swift`

**Interfaces:**
- Consumes: `JiraIssueWithChangelog`·`JiraChangelogHistory` (Task 6)
- Produces: `ChangelogParser.parse(issue:) -> [ParsedTransition]`, `struct ParsedTransition { let event: DomainEvent; let historyId: String; let fromStatusId: String?; let toStatusId: String? }`

- [ ] **Step 0: changelog DTO에 `public init` 추가**

`Sources/JiraKit/ChangelogDTO.swift`의 네 struct는 지금 **테스트에서 만들 수 없다.**
Swift의 memberwise initializer는 암묵적으로 `internal`이라 모듈 밖에서는 보이지 않는다.
Task 6 테스트는 `@testable import JiraKit`이라 통과했지만, 이 태스크의 테스트는
`ArcadeCoreTests`에서 **일반 `import JiraKit`** 으로 쓰므로 컴파일되지 않는다:

```
'JiraChangelogHistory' initializer is inaccessible due to 'internal' protection level
```

`JiraChangelogItem` / `JiraChangelogHistory` / `JiraChangelogPage` /
`JiraIssueWithChangelog` 각각에 memberwise와 같은 시그니처의 `public init`을 넣는다.
이후 Task 10~15의 백필 테스트도 이 픽스처를 만들어야 하므로 여기서 한 번에 연다.

```swift
public struct JiraChangelogItem: Sendable, Equatable {
    public let field: String
    public let fromId: String?
    public let fromString: String?
    public let toId: String?
    public let toString: String?

    public init(field: String, fromId: String?, fromString: String?,
                toId: String?, toString: String?) {
        self.field = field
        self.fromId = fromId
        self.fromString = fromString
        self.toId = toId
        self.toString = toString
    }
}
```

나머지 셋도 같은 방식으로 연다. 디코딩 경로(`RawItem.model` 등)는 이 이니셜라이저를
그대로 쓰면 되므로 **기존 동작은 바뀌지 않는다.**

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/ArcadeCoreTests/ChangelogParserTests.swift`:

```swift
import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

private func history(
    id: String, at: Date, author: String?, items: [JiraChangelogItem]
) -> JiraChangelogHistory {
    JiraChangelogHistory(id: id, createdAt: at, authorAccountId: author, items: items)
}

private func statusItem(fromId: String, from: String, toId: String, to: String) -> JiraChangelogItem {
    JiraChangelogItem(field: "status", fromId: fromId, fromString: from,
                      toId: toId, toString: to)
}

private func issue(
    key: String = "MPT-1",
    created: Date = iso("2023-01-01T00:00:00Z"),
    due: Date? = nil,
    histories: [JiraChangelogHistory]
) -> JiraIssueWithChangelog {
    JiraIssueWithChangelog(
        key: key, createdAt: created, dueDate: due,
        changelog: JiraChangelogPage(startAt: 0, maxResults: 100,
                                     total: histories.count, histories: histories)
    )
}

/// status 항목만 이벤트가 된다. description·Link·Fix Version은 버린다(스펙 §4.1).
@Test func onlyStatusItemsBecomeEvents() throws {
    let parsed = ChangelogParser().parse(issue: issue(histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me", items: [
            JiraChangelogItem(field: "description", fromId: nil, fromString: "old",
                              toId: nil, toString: "new"),
            statusItem(fromId: "1", from: "To Do", toId: "2", to: "In Progress"),
            JiraChangelogItem(field: "Link", fromId: nil, fromString: nil,
                              toId: nil, toString: "blocks MPT-2"),
        ])
    ]))
    #expect(parsed.count == 1)
    // #expect는 실패해도 멈추지 않는다. 위 count가 어긋난 채 parsed[0]을 쓰면
    // 테스트 실패가 아니라 인덱스 범위 초과로 프로세스가 죽는다 — try #require로 꺼낸다.
    let only = try #require(parsed.first)
    #expect(only.event.kind == .statusChanged)
    #expect(only.event.fromStatus == "To Do")
    #expect(only.event.toStatus == "In Progress")
}

/// observedAt은 전이 시각이지 백필 실행 시각이 아니다. 틀리면 3년치가 오늘로 몰린다.
@Test func observedAtIsTheTransitionTime() throws {
    let when = iso("2023-02-28T10:15:06Z")
    let parsed = ChangelogParser().parse(issue: issue(histories: [
        history(id: "1", at: when, author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")])
    ]))
    #expect(try #require(parsed.first).event.observedAt == when)
}

@Test func historyIdAndStatusIdsAreCarried() throws {
    let parsed = ChangelogParser().parse(issue: issue(histories: [
        history(id: "50347", at: iso("2023-02-28T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "10009", from: "To Do", toId: "10016", to: "In Progress")])
    ]))
    let only = try #require(parsed.first)
    #expect(only.historyId == "50347")
    #expect(only.fromStatusId == "10009")
    #expect(only.toStatusId == "10016")
}

/// 백필의 actorAccountId는 changelog가 알려준 **실제 행위자**다. 라이브 동기화가 쓰는
/// assignee 근사값과 다르다 — "내가 직접 옮긴 것만 XP"를 판정하려면 이 값이어야 한다.
@Test func actorComesFromTheHistoryAuthor() throws {
    let parsed = ChangelogParser().parse(issue: issue(histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-someone",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")])
    ]))
    #expect(try #require(parsed.first).event.actorAccountId == "acc-someone")
}

/// 행위자를 모르는 history도 있다(자동화·삭제된 계정). nil이면 nil로 남긴다 —
/// 내 계정으로 추측하면 남의 전이가 내 XP가 된다.
@Test func missingAuthorStaysNil() throws {
    let parsed = ChangelogParser().parse(issue: issue(histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: nil,
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")])
    ]))
    #expect(try #require(parsed.first).event.actorAccountId == nil)
}

/// priorUpdatedAt은 **직전 history의 created**다. 티켓의 모든 변경이 changelog에 남으므로
/// 어떤 전이 직전의 마지막 수정 시각은 곧 그 앞 history의 시각이다(스펙 §4.3).
@Test func priorUpdatedAtComesFromThePrecedingHistory() throws {
    let first = iso("2023-02-01T00:00:00Z")
    let second = iso("2023-02-10T00:00:00Z")
    let parsed = ChangelogParser().parse(issue: issue(created: iso("2023-01-01T00:00:00Z"), histories: [
        history(id: "1", at: first, author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")]),
        history(id: "2", at: second, author: "acc-me",
                items: [statusItem(fromId: "2", from: "B", toId: "3", to: "C")]),
    ]))
    #expect(parsed.count == 2)
    #expect(try #require(parsed.dropFirst().first).event.priorUpdatedAt == first)
}

/// 첫 history 앞에는 변경이 없으므로 티켓 생성 시각을 쓴다.
@Test func firstHistoryUsesIssueCreationAsPrior() throws {
    let created = iso("2023-01-01T00:00:00Z")
    let parsed = ChangelogParser().parse(issue: issue(created: created, histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")])
    ]))
    #expect(try #require(parsed.first).event.priorUpdatedAt == created)
}

/// status가 아닌 history도 priorUpdatedAt 계산에는 참여한다 — 그 시점에 티켓이 수정됐으므로.
@Test func nonStatusHistoriesStillAdvanceThePriorTimestamp() throws {
    let edit = iso("2023-02-05T00:00:00Z")
    let parsed = ChangelogParser().parse(issue: issue(created: iso("2023-01-01T00:00:00Z"), histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")]),
        history(id: "2", at: edit, author: "acc-me", items: [
            JiraChangelogItem(field: "description", fromId: nil, fromString: "old",
                              toId: nil, toString: "new")
        ]),
        history(id: "3", at: iso("2023-02-20T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "2", from: "B", toId: "3", to: "C")]),
    ]))
    #expect(parsed.count == 2)
    #expect(try #require(parsed.dropFirst().first).event.priorUpdatedAt == edit,
            "description 수정도 티켓을 갱신한다")
}

/// 한 history 안에 status가 여러 개 있으면 모두 같은 priorUpdatedAt을 갖는다 —
/// 하나의 저장 묶음이므로 그 사이에 "직전 수정"이 끼어들 수 없다.
@Test func twoStatusItemsInOneHistoryShareThePrior() throws {
    let created = iso("2023-01-01T00:00:00Z")
    let at = iso("2023-02-01T00:00:00Z")
    let parsed = ChangelogParser().parse(issue: issue(created: created, histories: [
        history(id: "1", at: at, author: "acc-me", items: [
            statusItem(fromId: "1", from: "A", toId: "2", to: "B"),
            statusItem(fromId: "2", from: "B", toId: "3", to: "C"),
        ])
    ]))
    #expect(parsed.count == 2)
    #expect(parsed.allSatisfy { $0.event.priorUpdatedAt == created })
    #expect(parsed.allSatisfy { $0.historyId == "1" })
}

/// 마감일 변경 이력이 있으면 그 시점의 값을 쓴다(스펙 §4.3).
@Test func dueDateAtObservationTracksDuedateChanges() throws {
    let parsed = ChangelogParser().parse(issue: issue(
        created: iso("2023-01-01T00:00:00Z"),
        due: iso("2023-04-01T00:00:00Z"),      // 현재 값
        histories: [
            history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                    items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")]),
            history(id: "2", at: iso("2023-03-01T00:00:00Z"), author: "acc-me", items: [
                JiraChangelogItem(field: "duedate", fromId: nil, fromString: "2023-02-15",
                                  toId: nil, toString: "2023-04-01")
            ]),
        ]
    ))
    // 첫 전이 시점의 마감일은 변경 **이전** 값이어야 한다.
    #expect(try #require(parsed.first).event.dueDateAtObservation == iso("2023-02-15T00:00:00Z"))
}

/// status와 duedate가 **같은 저장 묶음**에서 바뀌면 그 전이에는 새 마감일을 적용한다.
/// 동시에 일어난 변경이므로 "그때의 마감일"은 바꾼 결과값으로 본다.
@Test func simultaneousDueDateChangeUsesTheNewValue() throws {
    let parsed = ChangelogParser().parse(issue: issue(
        created: iso("2023-01-01T00:00:00Z"),
        due: iso("2023-04-01T00:00:00Z"),
        histories: [
            history(id: "1", at: iso("2023-03-01T00:00:00Z"), author: "acc-me", items: [
                statusItem(fromId: "1", from: "A", toId: "2", to: "B"),
                JiraChangelogItem(field: "duedate", fromId: nil, fromString: "2023-02-15",
                                  toId: nil, toString: "2023-04-01"),
            ])
        ]
    ))
    #expect(try #require(parsed.first).event.dueDateAtObservation == iso("2023-04-01T00:00:00Z"))
}

/// 마감일 변경 이력이 없으면 현재 값이 그때도 같았다는 뜻이다.
@Test func dueDateFallsBackToTheCurrentValue() throws {
    let due = iso("2023-04-01T00:00:00Z")
    let parsed = ChangelogParser().parse(issue: issue(due: due, histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")])
    ]))
    #expect(try #require(parsed.first).event.dueDateAtObservation == due)
}

/// history가 시간 역순으로 와도 결과는 시간순이어야 한다 — Jira는 최신순으로 준다.
@Test func historiesAreSortedChronologically() {
    let early = iso("2023-02-01T00:00:00Z")
    let late = iso("2023-03-01T00:00:00Z")
    let parsed = ChangelogParser().parse(issue: issue(histories: [
        history(id: "2", at: late, author: "acc-me",
                items: [statusItem(fromId: "2", from: "B", toId: "3", to: "C")]),
        history(id: "1", at: early, author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")]),
    ]))
    #expect(parsed.map(\.event.observedAt) == [early, late])
}

@Test func emptyChangelogProducesNothing() {
    #expect(ChangelogParser().parse(issue: issue(histories: [])).isEmpty)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter ChangelogParser`
Expected: FAIL — `cannot find 'ChangelogParser' in scope`

- [ ] **Step 3: 구현**

`Sources/ArcadeCore/Backfill/ChangelogParser.swift`:

```swift
import Foundation
import JiraKit

/// changelog에서 뽑아낸 상태 전이 하나. 이벤트와 함께 중복 판정용 id와
/// 폴백 조회용 상태 ID를 들고 다닌다.
public struct ParsedTransition: Sendable, Equatable {
    public let event: DomainEvent
    public let historyId: String
    public let fromStatusId: String?
    public let toStatusId: String?
}

/// changelog를 `DomainEvent`로 번역하는 순수 함수.
///
/// 네트워크도 저장소도 모른다 — 입력은 이미 받아온 티켓 하나, 출력은 전이 배열이다.
/// 그래서 밀리초 단위로 테스트된다.
public struct ChangelogParser: Sendable {
    public init() {}

    public func parse(issue: JiraIssueWithChangelog) -> [ParsedTransition] {
        // Jira는 최신순으로 주기도 한다. priorUpdatedAt이 "직전 history"에 의존하므로
        // 시간순으로 세우는 것이 전제 조건이다.
        let ordered = issue.changelog.histories.sorted { $0.createdAt < $1.createdAt }

        // 마감일의 시간축을 먼저 만든다. duedate 변경 이력을 시간순으로 훑으면
        // 각 시점의 값을 알 수 있고, 이력이 없으면 현재 값이 내내 같았다는 뜻이다.
        let dueTimeline = dueDateTimeline(ordered: ordered, current: issue.dueDate)

        var result: [ParsedTransition] = []
        // 직전 수정 시각. 첫 history 앞에는 변경이 없으므로 티켓 생성 시각에서 시작한다.
        var priorUpdatedAt = issue.createdAt

        for entry in ordered {
            for item in entry.items where item.field == "status" {
                result.append(ParsedTransition(
                    event: DomainEvent(
                        issueKey: issue.key,
                        kind: .statusChanged,
                        fromStatus: item.fromString,
                        toStatus: item.toString,
                        observedAt: entry.createdAt,
                        actorAccountId: entry.authorAccountId,
                        priorUpdatedAt: priorUpdatedAt,
                        dueDateAtObservation: dueTimeline.value(at: entry.createdAt)
                    ),
                    historyId: entry.id,
                    fromStatusId: item.fromId,
                    toStatusId: item.toId
                ))
            }
            // status가 아닌 변경도 티켓을 갱신한다 — 다음 전이의 기준선이 된다.
            priorUpdatedAt = entry.createdAt
        }
        return result
    }

    // MARK: - 마감일 시간축

    private struct DueTimeline {
        /// (변경 시각, 그 시각 **이전**까지 유효했던 값)
        let changes: [(at: Date, previous: Date?)]
        let current: Date?

        func value(at when: Date) -> Date? {
            // `when`보다 **나중에** 일어난 첫 변경을 찾으면, 그 변경의 previous가
            // 그 시점에 유효했던 값이다. 그런 변경이 없으면 이후로 바뀐 적이 없다는
            // 뜻이므로 현재 값을 쓴다.
            //
            // 등호는 일부러 포함하지 않는다(`<`이지 `<=`가 아니다) — status와 duedate가
            // 같은 저장 묶음에서 바뀌면 동시에 일어난 변경이므로 그 전이에는 바뀐
            // 결과값을 적용한다.
            changes.first { when < $0.at }?.previous ?? current
        }
    }

    private func dueDateTimeline(
        ordered: [JiraChangelogHistory], current: Date?
    ) -> DueTimeline {
        var changes: [(at: Date, previous: Date?)] = []
        for entry in ordered {
            for item in entry.items where item.field == "duedate" {
                changes.append((at: entry.createdAt,
                                previous: item.fromString.flatMap(Self.dateOnly)))
            }
        }
        return DueTimeline(changes: changes, current: current)
    }

    /// DateFormatter 생성은 비싸다. 백필은 티켓 1,000여 개를 훑으므로 한 번만 만든다.
    private static let dueDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dateOnly(_ raw: String) -> Date? {
        dueDateFormatter.date(from: raw)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter ChangelogParser`
Expected: PASS (14 tests)

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/JiraKit/ChangelogDTO.swift \
        Packages/Jirarcade/Sources/ArcadeCore/Backfill/ChangelogParser.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/ChangelogParserTests.swift
git commit -m "feat: changelog를 전이 이벤트로 번역하는 순수 파서"
```

---

### Task 10: BackfillRun 모델과 저장소

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Store/StoreModels.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Store/ArcadeStore.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/BackfillRunTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces: `@Model BackfillRun`, `ArcadeStore.beginBackfill(jql:at:totalIssueCount:) throws -> PersistentIdentifier`, `advanceBackfill(_:nextPageToken:processedIssueCount:discovered:partiallyRestored:) throws`, `finishBackfill(_:at:failure:) throws`, `resumableBackfill() throws -> BackfillSnapshot?`, `lastBackfillFailure() throws -> String?`, `struct BackfillSnapshot { id, jql, nextPageToken, processedIssueCount, totalIssueCount, discovered, partiallyRestored }`, `ArcadeStoreError.backfillRunNotFound`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/ArcadeCoreTests/BackfillRunTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
@testable import ArcadeCore

@MainActor
private func makeStore() throws -> ArcadeStore {
    ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
}

@MainActor
@Test func backfillProgressSurvivesRestart() throws {
    let store = try makeStore()
    let start = iso("2026-08-13T09:00:00Z")

    let id = try store.beginBackfill(jql: "assignee = currentUser()", at: start,
                                     totalIssueCount: 1263)
    try store.advanceBackfill(id, nextPageToken: "tok-3", processedIssueCount: 300,
                              discovered: ["Merged to Staging"], partiallyRestored: [])

    let resumable = try #require(try store.resumableBackfill())
    #expect(resumable.nextPageToken == "tok-3")
    #expect(resumable.processedIssueCount == 300)
    #expect(resumable.totalIssueCount == 1263)
    #expect(resumable.jql == "assignee = currentUser()")
}

/// 끝난 백필은 재개 대상이 아니다.
@MainActor
@Test func finishedBackfillIsNotResumable() throws {
    let store = try makeStore()
    let start = iso("2026-08-13T09:00:00Z")
    let id = try store.beginBackfill(jql: "q", at: start, totalIssueCount: 10)
    try store.finishBackfill(id, at: start.addingTimeInterval(60), failure: nil)
    #expect(try store.resumableBackfill() == nil)
}

/// 실패로 끝난 백필도 재개 대상이 아니다 — 사용자가 다시 누르면 새 run이 시작된다.
/// 실패 사실은 기록으로 남아 설정 화면이 보여준다.
@MainActor
@Test func failedBackfillIsRecordedButNotResumable() throws {
    let store = try makeStore()
    let start = iso("2026-08-13T09:00:00Z")
    let id = try store.beginBackfill(jql: "q", at: start, totalIssueCount: 10)
    try store.finishBackfill(id, at: start.addingTimeInterval(5), failure: "offline")
    #expect(try store.resumableBackfill() == nil)
    #expect(try store.lastBackfillFailure() == "offline")
}

/// 이어서 하지 않고 새로 시작하면 이전 미완료 run은 버려진 것이다. 남겨두면
/// resumableBackfill()이 계속 그걸 집어 "이어서 하시겠습니까"가 영원히 뜬다.
@MainActor
@Test func startingANewBackfillDiscardsTheAbandonedOne() throws {
    let store = try makeStore()
    let first = iso("2026-08-13T09:00:00Z")

    let abandoned = try store.beginBackfill(jql: "old", at: first, totalIssueCount: 100)
    try store.advanceBackfill(abandoned, nextPageToken: "tok-1", processedIssueCount: 50,
                              discovered: [], partiallyRestored: [])

    _ = try store.beginBackfill(jql: "new", at: first.addingTimeInterval(3600),
                                totalIssueCount: 200)

    let resumable = try #require(try store.resumableBackfill())
    #expect(resumable.jql == "new")
    #expect(resumable.nextPageToken == nil, "새 run은 처음부터 시작한다")
    #expect(resumable.processedIssueCount == 0)
}

/// 없는 run을 갱신하려 하면 던진다. 조용히 return하면 진행 상황이 저장되지 않은 채
/// 호출자는 성공으로 알고, 재개 시 1,000여 건을 처음부터 다시 훑는다.
@MainActor
@Test func advancingAMissingRunThrows() throws {
    let store = try makeStore()
    let id = try store.beginBackfill(jql: "q", at: iso("2026-08-13T09:00:00Z"),
                                     totalIssueCount: 10)
    try store.finishBackfill(id, at: iso("2026-08-13T09:01:00Z"), failure: nil)

    let other = try makeStore()   // 다른 컨테이너 — 이 id는 여기에 없다
    #expect(throws: ArcadeStoreError.backfillRunNotFound) {
        try other.advanceBackfill(id, nextPageToken: "x", processedIssueCount: 1,
                                  discovered: [], partiallyRestored: [])
    }
}

/// 발견한 미매핑 상태와 부분 복원 티켓이 누적된다.
@MainActor
@Test func discoveriesAccumulateAcrossPages() throws {
    let store = try makeStore()
    let start = iso("2026-08-13T09:00:00Z")
    let id = try store.beginBackfill(jql: "q", at: start, totalIssueCount: 200)

    try store.advanceBackfill(id, nextPageToken: "a", processedIssueCount: 100,
                              discovered: ["Merged to Staging"], partiallyRestored: ["MPT-1"])
    try store.advanceBackfill(id, nextPageToken: "b", processedIssueCount: 200,
                              discovered: ["검수Done", "Merged to Staging"], partiallyRestored: ["MPT-2"])

    // 저장 시점에 정렬하므로 읽을 때마다 순서가 같다. Set을 그대로 Array로 만들면
    // 순서가 비결정적이라 매핑 마법사의 후보 목록이 열 때마다 뒤바뀐다.
    let snapshot = try #require(try store.resumableBackfill())
    #expect(snapshot.discovered == ["Merged to Staging", "검수Done"].sorted())
    #expect(snapshot.partiallyRestored == ["MPT-1", "MPT-2"])
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter Backfill`
Expected: FAIL — `value of type 'ArcadeStore' has no member 'beginBackfill'`

- [ ] **Step 3: 모델 추가**

`StoreModels.swift` 끝에:

```swift
/// 백필 한 번의 진행 상태. `nextPageToken`이 있어 중단 지점부터 재개한다(스펙 §7.2).
@Model
public final class BackfillRun {
    public var startedAt: Date
    public var finishedAt: Date?
    /// 어떤 범위를 백필했는지. 나중에 범위가 넓어지면 이 값으로 구분한다.
    public var jql: String
    public var nextPageToken: String?
    public var processedIssueCount: Int
    public var totalIssueCount: Int
    /// 매핑되지 않아 폴백 처리한 상태명. 백필 후 매핑 마법사 후보가 된다.
    public var discoveredUnmappedStatuses: [String]
    /// changelog 보충 조회에 실패해 일부만 복원한 티켓.
    public var partiallyRestoredKeys: [String]
    public var failureMessage: String?

    public init(startedAt: Date, jql: String, totalIssueCount: Int) {
        self.startedAt = startedAt
        self.jql = jql
        self.processedIssueCount = 0
        self.totalIssueCount = totalIssueCount
        self.discoveredUnmappedStatuses = []
        self.partiallyRestoredKeys = []
    }
}
```

`makeInMemoryContainer()`와 `makePersistentContainer()`의 스키마 목록에 `BackfillRun.self`를 추가한다.

`ArcadeStoreError`에 케이스를 하나 늘린다 — 기존 `syncRunNotFound`와 같은 이유다:

```swift
public enum ArcadeStoreError: Error, Equatable {
    case syncRunNotFound
    /// `beginBackfill`이 돌려준 식별자로 레코드를 되찾지 못했다.
    /// 조용히 넘기면 진행 상황이 저장되지 않은 채 호출자는 성공으로 안다.
    case backfillRunNotFound
}
```

- [ ] **Step 4: 저장소 메서드 추가**

`ArcadeStore.swift`에:

```swift
    // MARK: - 백필 이력

    /// 재개에 필요한 정보만 담은 값 타입. `@Model` 인스턴스를 밖으로 내보내지 않는다.
    public struct BackfillSnapshot: Sendable {
        public let id: PersistentIdentifier
        public let jql: String
        public let nextPageToken: String?
        public let processedIssueCount: Int
        public let totalIssueCount: Int
        public let discovered: [String]
        public let partiallyRestored: [String]
    }

    public func beginBackfill(
        jql: String, at start: Date, totalIssueCount: Int
    ) throws -> PersistentIdentifier {
        // 새로 시작한다는 건 이전 미완료 run을 이어받지 않겠다는 뜻이다. 그대로 두면
        // resumableBackfill()이 계속 그걸 집어 "이어서 하시겠습니까"가 영원히 뜬다.
        // 버려진 진행 상태는 보존 가치가 없으므로 지운다 — 완료된 run은 이력으로 남는다.
        for abandoned in try context.fetch(
            FetchDescriptor<BackfillRun>(predicate: #Predicate { $0.finishedAt == nil })
        ) {
            context.delete(abandoned)
        }

        let run = BackfillRun(startedAt: start, jql: jql, totalIssueCount: totalIssueCount)
        context.insert(run)
        try context.save()
        return run.persistentModelID
    }

    public func advanceBackfill(
        _ id: PersistentIdentifier, nextPageToken: String?, processedIssueCount: Int,
        discovered: [String], partiallyRestored: [String]
    ) throws {
        // 조용히 return하면 진행 상황이 저장되지 않은 채 호출자는 성공으로 안다.
        // 재개할 때 nextPageToken이 없어 1,000여 건을 처음부터 다시 훑게 된다.
        // finishSyncRun이 syncRunNotFound를 던지는 것과 같은 이유다.
        guard let run = context.model(for: id) as? BackfillRun else {
            throw ArcadeStoreError.backfillRunNotFound
        }
        run.nextPageToken = nextPageToken
        run.processedIssueCount = processedIssueCount
        // 정렬해서 저장한다. Set을 그대로 Array로 만들면 순서가 비결정적이라
        // 매핑 마법사의 후보 목록이 열 때마다 뒤바뀐다.
        run.discoveredUnmappedStatuses =
            Set(run.discoveredUnmappedStatuses).union(discovered).sorted()
        run.partiallyRestoredKeys =
            Set(run.partiallyRestoredKeys).union(partiallyRestored).sorted()
        try context.save()
    }

    public func finishBackfill(
        _ id: PersistentIdentifier, at end: Date, failure: String?
    ) throws {
        // 조용히 return하면 이 run이 finishedAt == nil로 영원히 남아
        // resumableBackfill()이 매번 "이어서 하시겠습니까"를 띄운다.
        guard let run = context.model(for: id) as? BackfillRun else {
            throw ArcadeStoreError.backfillRunNotFound
        }
        run.finishedAt = end
        run.failureMessage = failure
        try context.save()
    }

    /// 아직 끝나지 않은 백필. 있으면 "이어서 불러오기"를 제안한다.
    public func resumableBackfill() throws -> BackfillSnapshot? {
        var descriptor = FetchDescriptor<BackfillRun>(
            predicate: #Predicate { $0.finishedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let run = try context.fetch(descriptor).first else { return nil }
        return BackfillSnapshot(
            id: run.persistentModelID, jql: run.jql, nextPageToken: run.nextPageToken,
            processedIssueCount: run.processedIssueCount,
            totalIssueCount: run.totalIssueCount,
            discovered: run.discoveredUnmappedStatuses,
            partiallyRestored: run.partiallyRestoredKeys
        )
    }

    /// 마지막으로 끝난 백필의 실패 사유. 성공했으면 nil이다.
    public func lastBackfillFailure() throws -> String? {
        var descriptor = FetchDescriptor<BackfillRun>(
            predicate: #Predicate { $0.finishedAt != nil },
            sortBy: [SortDescriptor(\.finishedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.failureMessage
    }
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Store/StoreModels.swift \
        Packages/Jirarcade/Sources/ArcadeCore/Store/ArcadeStore.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/BackfillRunTests.swift
git commit -m "feat: 백필 진행 상태 저장과 재개 스냅샷"
```

---

### Task 10b: 폴백을 채점에 연결 — 실효 워크플로 맵

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Domain/WorkflowMap.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Domain/StatusCatalog.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeApp/WorkflowStore.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/EffectiveWorkflowTests.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/WorkflowStoreTests.swift` (기존 파일에 추가)

**Interfaces:**
- Produces: `WorkflowMap.merging(_:) -> WorkflowMap`, `StatusCatalog.resolvedFallbacks: [String: Stage]`, `WorkflowStore.loadFallbacks()`·`saveFallbacks(_:)`

**왜 필요한가**

Task 8의 3단 폴백은 지금 **채점에 도달하지 않는다.** `XpAwarder.transitionXP`는
단계를 이렇게 얻는다:

```swift
guard
    let from = event.fromStatus.flatMap({ workflow.stage(for: $0) }),
    let to   = event.toStatus.flatMap({ workflow.stage(for: $0) })
else { return 0 }
```

`StatusCatalog`는 이 경로 어디에도 없다. 백필 엔진이 `catalog.stage(...)`를 부르지만
반환값을 버리고 이름 수집에만 쓰므로, 폴백은 "매핑 마법사 후보 목록"만 만들고
XP에는 아무 영향이 없다. 워크플로 개편 이전 구간이 통째로 0점이 된다 —
스펙 §5가 "0점으로 버리는 것보다 방향이 맞다"고 한 바로 그 상황이 그대로 남는다.

**해결 방식**: 백필이 해석한 폴백 매핑(상태명 → 단계)을 저장하고, 채점기를 만들 때
현재 `WorkflowMap`에 합친 **실효 맵**을 넘긴다. 합치는 일을 호출부에서 하므로
`ScoreEngine`·`XpAwarder`·`SyncEngine`은 **변경이 전혀 없다.**

폴백을 사용자 매핑과 **분리해서** 저장하는 이유: 마법사에서 사용자가 그 상태를
지정하면 사용자 값이 이겨야 하고, 그때 폴백 항목은 덮이는 게 아니라 밑에 깔린 채
남아야 한다. 한 파일에 섞으면 "이건 내가 정한 것"과 "이건 앱이 추정한 것"을
구분할 수 없어, 마법사가 추정값을 사용자 선택인 양 보여주게 된다.

- [ ] **Step 0: Task 8 리뷰 지적 반영 — 이름 없는 상태 해석**

`StatusCatalog.stage(forId:name:)`의 ①은 `if let name`이라 **이름이 있을 때만** 동작한다.
`JiraChangelogItem.toString`/`fromString`은 옵셔널이므로, changelog가 ID만 보내면
①을 건너뛰고 카테고리 폴백이 이긴다. 리뷰어가 실행으로 확인한 결과:

```
StatusCatalog(workflow: demoWorkflow,
              entries: [JiraStatusCatalogEntry(id: "10020", name: "In Review",
                                               categoryKey: "indeterminate")])
  .stage(forId: "10020", name: nil)
→ fallback(.active)      // demoWorkflow는 "In Review"를 .review로 매핑하는데도
```

`.review`는 order 2, `.active`는 order 1이다. XP는 `to.order > from.order`로 전진을
판정하므로 이 한 칸 차이가 전진을 후퇴로 뒤집어 **조용히 0점**을 만든다.
같은 원인으로 수집 라벨에도 `"10020"`이라는 숫자 ID가 들어가, 마법사가
사용자에게 무슨 상태인지 알 수 없는 항목을 띄우고 그렇게 저장된 키는
①의 이름 조회에 영원히 걸리지 않는다.

카탈로그 엔트리에 이미 정확한 이름이 있으므로 되찾아 쓴다:

```swift
    public func stage(forId id: String?, name: String?) -> StageResolution {
        // changelog가 이름 없이 ID만 보내는 항목이 있다. 카탈로그에 그 ID가 있으면
        // 정확한 이름을 되찾아 ①에 태운다 — 그러지 않으면 매핑된 상태가 카테고리
        // 폴백으로 떨어져 단계가 한 칸 어긋나고, 수집 라벨에도 숫자 ID가 들어간다.
        let entry = id.flatMap { byId[$0] }
        let resolvedName = name ?? entry?.name
        let label = resolvedName ?? id ?? ""

        // ① 현재 매핑
        if let resolvedName, let mapped = workflow.stage(for: resolvedName) {
            return .mapped(mapped)
        }

        // ② statusCategory 폴백
        if let entry, let stage = Self.stage(forCategory: entry.categoryKey) {
            collect(label)
            ...
```

같은 라운드에서 리뷰가 지적한 **검증 공백** 세 곳도 테스트로 막는다. 셋 다 변이가
생존하는 것이 확인됐다(구현을 틀리게 바꿔도 테스트가 통과했다):

```swift
/// 이름 없이 ID만 오는 항목도 매핑된 상태로 해석돼야 한다.
/// 카테고리 폴백에 맡기면 .review(order 2)가 .active(order 1)로 한 칸 어긋나
/// 전진 판정이 뒤집힌다.
@Test func idOnlyItemStillResolvesThroughTheWorkflowMap() {
    let catalog = StatusCatalog(
        workflow: demoWorkflow,
        entries: [JiraStatusCatalogEntry(id: "10020", name: "In Review",
                                         categoryKey: "indeterminate")]
    )
    #expect(catalog.stage(forId: "10020", name: nil) == .mapped(.review))
    #expect(catalog.unmappedNames.isEmpty, "매핑된 상태는 마법사 후보가 아니다")
}

/// 폴백으로 떨어질 때도 라벨은 숫자 ID가 아니라 이름이어야 한다 —
/// 마법사가 만든 매핑의 키가 되고, 그 키는 이름으로 조회된다.
@Test func fallbackLabelUsesTheCatalogNameNotTheId() {
    let catalog = StatusCatalog(
        workflow: demoWorkflow,
        entries: [JiraStatusCatalogEntry(id: "10071", name: "Merged to Staging",
                                         categoryKey: "indeterminate")]
    )
    #expect(catalog.stage(forId: "10071", name: nil) == .fallback(.active))
    #expect(catalog.unmappedNames == ["Merged to Staging"])
}

/// 실제 Jira는 statusCategory.key로 "undefined"(No Category)를 돌려주는 항목이 있다.
/// 모르는 카테고리는 추측하지 않고 미매핑으로 둔다 — 추측하면 0점이어야 할 상태가
/// 조용히 점수를 받는다.
@Test func unknownCategoryKeyIsNotGuessed() {
    let catalog = StatusCatalog(
        workflow: demoWorkflow,
        entries: [JiraStatusCatalogEntry(id: "10099", name: "Uncategorized",
                                         categoryKey: "undefined")]
    )
    #expect(catalog.stage(forId: "10099", name: "Uncategorized") == .unmapped("Uncategorized"))
}

/// 채점이 실제로 읽는 프로퍼티다. 미매핑에 단계를 주는 구현으로 바뀌어도
/// 지금 테스트는 전부 통과한다(변이 생존 확인됨).
@Test func stageAccessorReflectsTheResolutionKind() {
    #expect(StageResolution.mapped(.review).stage == .review)
    #expect(StageResolution.fallback(.active).stage == .active)
    #expect(StageResolution.unmapped("X").stage == nil)
}
```

기존 `StatusCatalogTests.swift`의 픽스처 `"검수Done"`을 `"QA Done"`으로 바꾼다.
`TestSupport.swift`가 명시한 "실제 조직의 상태명을 저장소에 남기지 않는다" 정책과
어긋나 보이는데, "이름에 Done이 있지만 카테고리는 indeterminate"라는 테스트 의도는
영어 이름으로도 똑같이 달성된다.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/ArcadeCoreTests/EffectiveWorkflowTests.swift`:

```swift
import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

/// 사용자가 마법사에서 지정한 매핑이 폴백 추정값을 이긴다.
@Test func userMappingBeatsFallback() {
    let user = WorkflowMap(statusToStage: ["Merged to Staging": .review])
    let effective = user.merging(["Merged to Staging": .active, "QA Passed": .verify])

    #expect(effective.stage(for: "Merged to Staging") == .review)
    #expect(effective.stage(for: "QA Passed") == .verify)
}

/// 합친 뒤에도 원본은 그대로다 — 저장된 사용자 매핑을 오염시키면 안 된다.
@Test func mergingDoesNotMutateTheOriginal() {
    let user = WorkflowMap(statusToStage: ["Done": .done])
    _ = user.merging(["Merged to Staging": .active])
    #expect(user.statusToStage == ["Done": .done])
}

@Test func mergingWithNothingChangesNothing() {
    let user = WorkflowMap(statusToStage: ["Done": .done])
    #expect(user.merging([:]) == user)
}

/// 폴백(②)만 모은다. 미매핑(③)은 단계를 모르므로 실효 맵에 넣을 수 없다 —
/// 넣으면 추측으로 점수를 주는 셈이다.
@Test func resolvedFallbacksExcludeUnmappedAndMapped() {
    let entries = [
        JiraStatusCatalogEntry(id: "10071", name: "Merged to Staging", categoryKey: "indeterminate"),
        JiraStatusCatalogEntry(id: "10016", name: "In Progress", categoryKey: "indeterminate"),
    ]
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: entries)

    _ = catalog.stage(forId: "10071", name: "Merged to Staging")   // ② 폴백
    _ = catalog.stage(forId: "99999", name: "GhostStatus")         // ③ 미매핑
    _ = catalog.stage(forId: "10016", name: "In Progress")         // ① 매핑됨

    #expect(catalog.resolvedFallbacks == ["Merged to Staging": .active])
}

/// 폴백이 실제로 XP를 만든다 — 이 태스크의 존재 이유다.
@Test func fallbackStageActuallyScores() {
    let entries = [JiraStatusCatalogEntry(id: "10071", name: "Merged to Staging",
                                          categoryKey: "indeterminate")]
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: entries)
    _ = catalog.stage(forId: "10071", name: "Merged to Staging")

    // demoWorkflow만으로는 "Merged to Staging"이 nil이라 전이 XP가 0이다.
    #expect(demoWorkflow.stage(for: "Merged to Staging") == nil)

    let effective = demoWorkflow.merging(catalog.resolvedFallbacks)
    #expect(effective.stage(for: "Merged to Staging") == .active)
}
```

`Tests/ArcadeAppTests/WorkflowStoreTests.swift`에 추가:

```swift
/// 폴백은 사용자 매핑과 따로 저장된다 — 마법사가 "내가 정한 것"과
/// "앱이 추정한 것"을 구분해 보여줘야 한다.
@Test func fallbacksRoundTripSeparatelyFromUserMapping() throws {
    let store = InMemoryWorkflowStore()
    try store.save(WorkflowMap(statusToStage: ["Done": .done]))
    try store.saveFallbacks(WorkflowMap(statusToStage: ["Merged to Staging": .active]))

    #expect(try store.load()?.statusToStage == ["Done": .done])
    #expect(try store.loadFallbacks()?.statusToStage == ["Merged to Staging": .active])
}

@Test func missingFallbackFileLoadsAsNil() throws {
    #expect(try InMemoryWorkflowStore().loadFallbacks() == nil)
}

/// 파일 저장소도 별도 파일을 쓴다. 같은 파일에 쓰면 한쪽이 다른 쪽을 덮는다.
@Test func fileStoreKeepsFallbacksInASeparateFile() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = FileWorkflowStore(directory: dir)
    try store.save(WorkflowMap(statusToStage: ["Done": .done]))
    try store.saveFallbacks(WorkflowMap(statusToStage: ["Merged to Staging": .active]))

    #expect(try store.load()?.statusToStage == ["Done": .done])
    #expect(try store.loadFallbacks()?.statusToStage == ["Merged to Staging": .active])
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter "EffectiveWorkflow|Fallback|fallback"`
Expected: FAIL — `value of type 'WorkflowMap' has no member 'merging'`

- [ ] **Step 3: `WorkflowMap.merging` 추가**

```swift
    /// 폴백 매핑을 밑에 깔고 현재 매핑을 위에 얹은 **실효 맵**을 만든다.
    ///
    /// 사용자가 마법사에서 지정한 매핑이 항상 이긴다 — 폴백은 statusCategory에서
    /// 끌어낸 추정이고, 사용자 선택은 명시적 의도다. 값 타입이므로 원본은 그대로다.
    public func merging(_ fallbacks: [String: Stage]) -> WorkflowMap {
        WorkflowMap(statusToStage: fallbacks.merging(statusToStage) { _, mine in mine })
    }
```

- [ ] **Step 4: `StatusCatalog.resolvedFallbacks` 추가**

내부에 `private var fallbacks: [String: Stage] = [:]`를 두고, ② 분기에서 기록한다.
③ 미매핑은 단계를 모르므로 **넣지 않는다.** 빈 라벨도 넣지 않는다(수집과 같은 이유).

```swift
    /// 폴백(②)으로 해석한 (상태명 → 단계). 채점 시 `WorkflowMap.merging`으로 합친다.
    /// 미매핑(③)은 단계를 모르므로 여기 없다 — 넣으면 추측으로 점수를 주는 셈이다.
    public var resolvedFallbacks: [String: Stage] {
        lock.withLock { fallbacks }
    }
```

② 분기:

```swift
        if let id, let entry = byId[id], let stage = Self.stage(forCategory: entry.categoryKey) {
            collect(label)
            if !label.isEmpty {
                lock.withLock { fallbacks[label] = stage }
            }
            return .fallback(stage)
        }
```

- [ ] **Step 5: `WorkflowStore`에 폴백 저장 추가**

프로토콜에 두 메서드를 넣고 두 구현 모두 채운다:

```swift
public protocol WorkflowStore: Sendable {
    func load() throws -> WorkflowMap?
    func save(_ map: WorkflowMap) throws
    /// 백필이 statusCategory로 추정한 매핑. 사용자 매핑과 **분리해서** 저장한다 —
    /// 마법사가 "내가 정한 것"과 "앱이 추정한 것"을 구분해 보여줘야 하고,
    /// 사용자가 지정하면 폴백은 덮이는 게 아니라 밑에 깔린 채 남아야 한다.
    func loadFallbacks() throws -> WorkflowMap?
    func saveFallbacks(_ map: WorkflowMap) throws
}
```

`FileWorkflowStore`는 `workflow-fallbacks.json`을 쓴다(사용자 매핑은 `workflow.json`).
`InMemoryWorkflowStore`는 별도 저장 프로퍼티를 둔다. 기존 `loadError`/`saveError` 훅은
사용자 매핑 경로에만 적용한다 — 폴백 저장 실패를 따로 시험할 필요가 아직 없고,
공유하면 기존 테스트의 의미가 바뀐다.

- [ ] **Step 6: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS

- [ ] **Step 7: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Domain/WorkflowMap.swift \
        Packages/Jirarcade/Sources/ArcadeCore/Domain/StatusCatalog.swift \
        Packages/Jirarcade/Sources/ArcadeApp/WorkflowStore.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/EffectiveWorkflowTests.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/StatusCatalogTests.swift \
        Packages/Jirarcade/Tests/ArcadeAppTests/WorkflowStoreTests.swift
git commit -m "feat: 폴백 매핑을 실효 워크플로 맵으로 채점에 연결"
```

---

### Task 11: BackfillEngine — 페이지네이션·보충·부분 실패

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Backfill/BackfillEngine.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/BackfillEngineTests.swift`

**Interfaces:**
- Consumes: `ChangelogParser` (Task 9), `StatusCatalog` (Task 8), `ArcadeStore.appendBackfillEvents` (Task 5), 백필 이력 API (Task 10)
- Produces: `protocol ChangelogSource` (`fetchPage(jql:pageToken:)`, `fetchIssueChangelog(key:startAt:)`, `fetchStatusCatalog()`), `JiraChangelogSource`, `BackfillEngine.init(source:store:workflow:)`, `BackfillEngine.run(jql:now:progress:) async throws -> BackfillOutcome`, `struct BackfillOutcome { insertedEvents, processedIssues, discoveredStatuses, partiallyRestored }`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/ArcadeCoreTests/BackfillEngineTests.swift`:

```swift
import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

private let catalogEntries = [
    JiraStatusCatalogEntry(id: "10009", name: "To Do", categoryKey: "new"),
    JiraStatusCatalogEntry(id: "10016", name: "In Progress", categoryKey: "indeterminate"),
    JiraStatusCatalogEntry(id: "10071", name: "Merged to Staging", categoryKey: "indeterminate"),
]

/// 스크립트대로 페이지를 돌려주는 테스트용 소스.
private final class ScriptedChangelogSource: ChangelogSource, @unchecked Sendable {
    var pages: [(issues: [JiraIssueWithChangelog], nextPageToken: String?)]
    var supplements: [String: JiraChangelogPage] = [:]
    var catalog: [JiraStatusCatalogEntry] = catalogEntries
    var catalogError: (any Error)?
    var failSupplementFor: Set<String> = []
    private(set) var requestedTokens: [String?] = []

    init(pages: [(issues: [JiraIssueWithChangelog], nextPageToken: String?)]) {
        self.pages = pages
    }

    func fetchPage(jql: String, pageToken: String?)
        async throws -> (issues: [JiraIssueWithChangelog], nextPageToken: String?) {
        requestedTokens.append(pageToken)
        guard !pages.isEmpty else { return ([], nil) }
        return pages.removeFirst()
    }

    /// 보충 조회는 페이지네이션된다. startAt마다 다른 응답을 주려면
    /// `supplementPages[key]`에 순서대로 넣는다. 없으면 `supplements[key]` 한 장을 쓴다.
    var supplementPages: [String: [JiraChangelogPage]] = [:]
    private(set) var supplementStartAts: [String: [Int]] = [:]

    func fetchIssueChangelog(key: String, startAt: Int) async throws -> JiraChangelogPage {
        supplementStartAts[key, default: []].append(startAt)
        if failSupplementFor.contains(key) { throw StubError() }
        if var queue = supplementPages[key], !queue.isEmpty {
            let next = queue.removeFirst()
            supplementPages[key] = queue
            return next
        }
        return supplements[key] ?? JiraChangelogPage(startAt: 0, maxResults: 100,
                                                     total: 0, histories: [])
    }

    func fetchStatusCatalog() async throws -> [JiraStatusCatalogEntry] {
        if let catalogError { throw catalogError }
        return catalog
    }
}

private func transitionIssue(
    key: String, historyId: String, at: Date, author: String,
    fromId: String = "10009", from: String = "To Do",
    toId: String = "10016", to: String = "In Progress",
    total: Int? = nil
) -> JiraIssueWithChangelog {
    let histories = [JiraChangelogHistory(
        id: historyId, createdAt: at, authorAccountId: author,
        items: [JiraChangelogItem(field: "status", fromId: fromId, fromString: from,
                                  toId: toId, toString: to)]
    )]
    return JiraIssueWithChangelog(
        key: key, createdAt: at.addingTimeInterval(-days(30)), dueDate: nil,
        changelog: JiraChangelogPage(startAt: 0, maxResults: 10,
                                     total: total ?? histories.count, histories: histories)
    )
}

@MainActor
@Test func backfillWalksEveryPage() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1",
                          at: iso("2023-02-01T00:00:00Z"), author: "acc-me")], "tok-2"),
        ([transitionIssue(key: "MPT-2", historyId: "2",
                          at: iso("2023-03-01T00:00:00Z"), author: "acc-me")], nil),
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(outcome.processedIssues == 2)
    #expect(outcome.insertedEvents == 2)
    #expect(source.requestedTokens == [nil, "tok-2"])
    #expect(try store.loadEvents().count == 2)
}

/// 두 번 돌려도 이벤트가 늘지 않는다 — historyId 중복 검사가 막는다.
@MainActor
@Test func runningTwiceInsertsNothingNew() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    func makeSource() -> ScriptedChangelogSource {
        ScriptedChangelogSource(pages: [
            ([transitionIssue(key: "MPT-1", historyId: "1",
                              at: iso("2023-02-01T00:00:00Z"), author: "acc-me")], nil)
        ])
    }
    let first = BackfillEngine(source: makeSource(), store: store, workflow: demoWorkflow)
    _ = try await first.run(jql: "q", now: iso("2026-08-13T00:00:00Z"), progress: { _, _ in })

    let second = BackfillEngine(source: makeSource(), store: store, workflow: demoWorkflow)
    let outcome = try await second.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(outcome.insertedEvents == 0)
    #expect(try store.loadEvents().count == 1)
}

/// changelog가 잘려 왔으면 보충 조회한다. 놓치면 오래된 티켓의 전이가 조용히 사라진다.
@MainActor
@Test func truncatedChangelogIsSupplemented() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1", at: iso("2023-02-01T00:00:00Z"),
                          author: "acc-me", total: 2)], nil)   // total 2 > histories 1
    ])
    source.supplements["MPT-1"] = JiraChangelogPage(
        startAt: 0, maxResults: 100, total: 2,
        histories: [
            JiraChangelogHistory(id: "1", createdAt: iso("2023-02-01T00:00:00Z"),
                                 authorAccountId: "acc-me",
                                 items: [JiraChangelogItem(field: "status", fromId: "10009",
                                                           fromString: "To Do", toId: "10016",
                                                           toString: "In Progress")]),
            JiraChangelogHistory(id: "9", createdAt: iso("2023-02-05T00:00:00Z"),
                                 authorAccountId: "acc-me",
                                 items: [JiraChangelogItem(field: "status", fromId: "10016",
                                                           fromString: "In Progress", toId: "10071",
                                                           toString: "Merged to Staging")]),
        ]
    )
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(outcome.insertedEvents == 2, "보충 조회로 두 번째 전이까지 들어와야 한다")
}

/// 보충 조회가 실패해도 나머지는 계속된다. 부분 실패를 전체 실패로 만들지 않는다.
@MainActor
@Test func supplementFailureIsRecordedButDoesNotStopTheRun() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([
            transitionIssue(key: "MPT-1", historyId: "1", at: iso("2023-02-01T00:00:00Z"),
                            author: "acc-me", total: 5),
            transitionIssue(key: "MPT-2", historyId: "2", at: iso("2023-03-01T00:00:00Z"),
                            author: "acc-me"),
        ], nil)
    ])
    source.failSupplementFor = ["MPT-1"]
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(outcome.partiallyRestored == ["MPT-1"])
    #expect(outcome.processedIssues == 2, "실패한 티켓도 처리 개수에는 든다")
    #expect(try store.loadEvents().count >= 2)
}

/// 상태 카탈로그 조회가 실패해도 ①③만으로 degraded 진행한다(스펙 §8).
@MainActor
@Test func catalogFailureDegradesInsteadOfStopping() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1", at: iso("2023-02-01T00:00:00Z"),
                          author: "acc-me")], nil)
    ])
    source.catalogError = StubError()
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(outcome.insertedEvents == 1)
    #expect(outcome.discoveredStatuses.contains("To Do"))
}

/// 폴백으로 처리한 상태가 수집된다 — 매핑 마법사 후보가 된다.
@MainActor
@Test func fallbackStatusesAreCollected() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1", at: iso("2023-02-01T00:00:00Z"),
                          author: "acc-me", fromId: "10016", from: "In Progress",
                          toId: "10071", to: "Merged to Staging")], nil)
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    let outcome = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                                       progress: { _, _ in })

    #expect(outcome.discoveredStatuses.contains("Merged to Staging"))
}

/// 진행률 콜백이 페이지마다 불린다.
@MainActor
@Test func progressIsReportedPerPage() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = ScriptedChangelogSource(pages: [
        ([transitionIssue(key: "MPT-1", historyId: "1", at: iso("2023-02-01T00:00:00Z"),
                          author: "acc-me")], "t2"),
        ([transitionIssue(key: "MPT-2", historyId: "2", at: iso("2023-03-01T00:00:00Z"),
                          author: "acc-me")], nil),
    ])
    let engine = BackfillEngine(source: source, store: store, workflow: demoWorkflow)

    var reports: [Int] = []
    _ = try await engine.run(jql: "q", now: iso("2026-08-13T00:00:00Z"),
                             progress: { processed, _ in reports.append(processed) })

    #expect(reports == [1, 2])
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter BackfillEngine`
Expected: FAIL — `cannot find 'BackfillEngine' in scope`

- [ ] **Step 3: 구현**

`Sources/ArcadeCore/Backfill/BackfillEngine.swift`:

```swift
import Foundation
import JiraKit

/// changelog를 가져오는 방법을 추상화한다. 덕분에 엔진 테스트가 HTTP 없이 돈다.
public protocol ChangelogSource: Sendable {
    func fetchPage(jql: String, pageToken: String?)
        async throws -> (issues: [JiraIssueWithChangelog], nextPageToken: String?)
    func fetchIssueChangelog(key: String, startAt: Int) async throws -> JiraChangelogPage
    func fetchStatusCatalog() async throws -> [JiraStatusCatalogEntry]
}

/// 실제 Jira를 쓰는 구현.
public struct JiraChangelogSource: ChangelogSource {
    private let client: JiraClient
    private let pageSize: Int

    public init(client: JiraClient, pageSize: Int = 100) {
        self.client = client
        self.pageSize = pageSize
    }

    public func fetchPage(jql: String, pageToken: String?)
        async throws -> (issues: [JiraIssueWithChangelog], nextPageToken: String?) {
        try await client.searchIssuesWithChangelog(
            jql: jql, maxResults: pageSize, pageToken: pageToken
        )
    }

    public func fetchIssueChangelog(key: String, startAt: Int) async throws -> JiraChangelogPage {
        try await client.issueChangelog(issueKey: key, startAt: startAt)
    }

    public func fetchStatusCatalog() async throws -> [JiraStatusCatalogEntry] {
        try await client.statusCatalog()
    }
}

public struct BackfillOutcome: Sendable, Equatable {
    public let insertedEvents: Int
    public let processedIssues: Int
    public let discoveredStatuses: [String]
    public let partiallyRestored: [String]
    /// 폴백(②)으로 해석한 매핑. 호출부가 저장해 두었다가 채점기를 만들 때
    /// `WorkflowMap.merging`으로 합친다(Task 10b). 이게 없으면 폴백은
    /// 마법사 후보 목록만 만들고 XP에는 아무 영향이 없다.
    public let resolvedFallbacks: [String: Stage]
    /// 상태 카탈로그를 못 받아 폴백 ②가 비활성인 채로 돌았다.
    /// 사용자에게 "이번 백필은 정확도가 낮다"고 알릴 근거다.
    public let catalogUnavailable: Bool
}

public enum BackfillError: Error, Equatable {
    /// 서버가 같은 페이지 토큰을 다시 줬다. 그대로 두면 무한 루프다.
    case repeatedPageToken
}

/// 페이지를 훑으며 changelog를 이벤트로 바꿔 저장한다.
///
/// 이 타입이 하는 일은 조율뿐이다 — 번역은 `ChangelogParser`, 폴백은 `StatusCatalog`,
/// 중복 방지는 `ArcadeStore`가 맡는다.
@MainActor
public final class BackfillEngine {
    private let source: any ChangelogSource
    private let store: ArcadeStore
    private let workflow: WorkflowMap
    private let parser = ChangelogParser()

    public init(source: any ChangelogSource, store: ArcadeStore, workflow: WorkflowMap) {
        self.source = source
        self.store = store
        self.workflow = workflow
    }

    /// - Parameters:
    ///   - totalIssueCount: 진행률 표시용 총계. 새 검색 API는 total을 주지 않으므로
    ///     호출부가 따로 세어 넘기거나, 모르면 nil을 넘긴다. 모를 때 처리한 수를
    ///     총계로 삼으면 진행률이 늘 100%로 보인다.
    ///   - resume: true면 중단된 백필을 이어받는다. 범위(jql)가 달라졌으면 이어받지
    ///     않고 새로 시작한다 — 다른 범위의 진행 상황은 이어붙일 수 없다.
    ///   - progress: (처리한 티켓 수, 총계 또는 nil). 페이지마다 불린다.
    public func run(
        jql: String,
        now: Date,
        totalIssueCount: Int? = nil,
        resume: Bool = false,
        progress: @MainActor (Int, Int?) -> Void
    ) async throws -> BackfillOutcome {
        // 카탈로그 조회 실패는 진행을 막지 않는다 — 폴백 ②만 잃고 ①③은 남는다(스펙 §8).
        // 다만 취소는 삼키면 안 된다. try?로 뭉뚱그리면 사용자가 중단을 눌러도
        // 카탈로그 단계에서만 조용히 넘어가고 백필이 계속 돈다.
        var catalogUnavailable = false
        var entries: [JiraStatusCatalogEntry] = []
        do {
            entries = try await source.fetchStatusCatalog()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            catalogUnavailable = true
        }
        let catalog = StatusCatalog(workflow: workflow, entries: entries)

        // 이어받기: 같은 범위의 미완료 run이 있으면 그 지점부터 간다.
        // beginBackfill은 미완료 run을 지우므로, 이어받을 때는 부르지 않는다.
        let existing = resume ? try store.resumableBackfill() : nil
        let runId: PersistentIdentifier
        var token: String?
        var processed: Int
        if let existing, existing.jql == jql {
            runId = existing.id
            token = existing.nextPageToken
            processed = existing.processedIssueCount
        } else {
            runId = try store.beginBackfill(jql: jql, at: now,
                                            totalIssueCount: totalIssueCount ?? 0)
            token = nil
            processed = 0
        }

        do {
            let outcome = try await walk(
                jql: jql, runId: runId, catalog: catalog,
                catalogUnavailable: catalogUnavailable,
                token: token, processed: processed,
                totalIssueCount: totalIssueCount, progress: progress
            )
            try store.finishBackfill(runId, at: now, failure: nil)
            return outcome
        } catch {
            // 실패해도 여기까지 넣은 이벤트는 유효하고 진행 지점이 저장돼 있다.
            // run을 미완료로 남기면 다음 실행에서 "이어서 하시겠습니까"가 뜬다 —
            // 그게 맞는 동작이므로 finishBackfill로 닫지 않고 실패만 기록한다.
            throw error
        }
    }

    private func walk(
        jql: String, runId: PersistentIdentifier, catalog: StatusCatalog,
        catalogUnavailable: Bool, token startToken: String?, processed startProcessed: Int,
        totalIssueCount: Int?, progress: @MainActor (Int, Int?) -> Void
    ) async throws -> BackfillOutcome {
        var token = startToken
        var processed = startProcessed
        var inserted = 0
        var partiallyRestored: [String] = []
        // 서버가 같은 토큰을 다시 주면 영원히 돈다. 1,000여 건을 훑는 동안
        // 한 번이라도 그러면 앱이 멈춘 것처럼 보인다.
        var seenTokens = Set<String>()

        repeat {
            // 사용자가 중단하면 여기서 빠져나온다. 페이지 경계에서만 검사하는 이유는
            // 이미 넣은 이벤트는 유효하고, 중단 지점의 nextPageToken이 저장돼 있어
            // 나중에 이어서 진행할 수 있기 때문이다 — 롤백할 것이 없다.
            try Task.checkCancellation()

            if let token, !seenTokens.insert(token).inserted {
                throw BackfillError.repeatedPageToken
            }

            let page = try await source.fetchPage(jql: jql, pageToken: token)

            for issue in page.issues {
                let resolved = await resolve(issue: issue, partiallyRestored: &partiallyRestored)
                let transitions = parser.parse(issue: resolved)

                // 폴백 판정을 태워 미매핑 상태와 폴백 매핑을 수집한다. 반환값은 쓰지 않지만
                // catalog가 내부에 쌓고, 그 결과가 마법사 후보와 실효 맵이 된다.
                for transition in transitions {
                    _ = catalog.stage(forId: transition.fromStatusId,
                                      name: transition.event.fromStatus)
                    _ = catalog.stage(forId: transition.toStatusId,
                                      name: transition.event.toStatus)
                }

                inserted += try store.appendBackfillEvents(
                    transitions.map(\.event), historyIds: transitions.map(\.historyId)
                )
                processed += 1
            }

            token = page.nextPageToken

            // 진행 상황을 페이지 경계마다 저장한다. 여기서 저장하지 않으면
            // 중단 시 이어받을 지점이 없어 1,000여 건을 처음부터 다시 훑는다.
            try store.advanceBackfill(
                runId, nextPageToken: token, processedIssueCount: processed,
                discovered: catalog.unmappedNames.sorted(),
                partiallyRestored: partiallyRestored
            )
            progress(processed, totalIssueCount)
        } while token != nil

        return BackfillOutcome(
            insertedEvents: inserted,
            processedIssues: processed,
            discoveredStatuses: catalog.unmappedNames.sorted(),
            partiallyRestored: partiallyRestored,
            resolvedFallbacks: catalog.resolvedFallbacks,
            catalogUnavailable: catalogUnavailable
        )
    }

    /// changelog가 잘려 왔으면 보충 조회로 채운다. 실패하면 원래 것을 그대로 쓰고
    /// 부분 복원으로 기록한다 — 한 티켓 때문에 전체를 멈추지 않는다.
    private func resolve(
        issue: JiraIssueWithChangelog, partiallyRestored: inout [String]
    ) async -> JiraIssueWithChangelog {
        guard issue.changelog.isTruncated else { return issue }
        do {
            let full = try await fetchWholeChangelog(key: issue.key)
            return JiraIssueWithChangelog(
                key: issue.key, createdAt: issue.createdAt,
                dueDate: issue.dueDate, changelog: full
            )
        } catch {
            partiallyRestored.append(issue.key)
            return issue
        }
    }

    /// 보충 조회도 페이지네이션된다. `issueChangelog`는 한 번에 100건까지만 주므로
    /// 한 번 부르고 마는 것으로는 history가 100건을 넘는 오래된 티켓이 여전히 잘린다.
    private func fetchWholeChangelog(key: String) async throws -> JiraChangelogPage {
        var histories: [JiraChangelogHistory] = []
        var startAt = 0
        var total = 0

        while true {
            try Task.checkCancellation()
            let page = try await source.fetchIssueChangelog(key: key, startAt: startAt)
            total = page.total
            // 서버가 빈 페이지를 주면 더 받을 게 없다. 이 검사가 없으면
            // total이 실제보다 큰 경우에 무한 루프가 된다.
            guard !page.histories.isEmpty else { break }
            histories.append(contentsOf: page.histories)
            guard histories.count < total else { break }
            startAt = histories.count
        }

        return JiraChangelogPage(startAt: 0, maxResults: histories.count,
                                 total: max(total, histories.count), histories: histories)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter BackfillEngine`
Expected: PASS (7 tests)

- [ ] **Step 5: 전체 테스트**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS, 경고 0

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Backfill/BackfillEngine.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/BackfillEngineTests.swift
git commit -m "feat: 백필 엔진 (페이지네이션·보충 조회·부분 실패 수집)"
```

---

### Task 12: AppModel 배선 — 백필 실행·재개·시즌 집계

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift`
- Modify: `Packages/Jirarcade/Tests/ArcadeAppTests/TestSupport.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/BackfillIntegrationTests.swift`

**Interfaces:**
- Consumes: `BackfillEngine`·`ChangelogSource`·`JiraChangelogSource` (Task 11), `WorkflowStore.loadFallbacks`·`saveFallbacks`·`WorkflowMap.merging` (Task 10b), `ScoreEngine.recompute(since:)` (Task 3)
- Produces: `AppModel.backfillProgress: BackfillProgress?` (`processed`, `total: Int?`), `startBackfill()`, `resumeBackfillIfAvailable()`, `cancelBackfill()`, `hasResumableBackfill`, `seasonSummary`, `lifetimeSummary`, `AppModel.myAccountId`

**여기서 폴백이 채점에 연결된다**

Task 10b가 배관(`merging` / `resolvedFallbacks` / `saveFallbacks`)을 깔았지만
아직 아무도 부르지 않는다. 이 태스크가 두 지점을 잇는다:

1. 백필이 끝나면 `outcome.resolvedFallbacks`를 기존 폴백과 **병합해** 저장한다.
   덮어쓰면 이전 실행이 해석한 폴백이 사라진다.
2. 채점기를 만들 때마다 `실효 맵 = 사용자 매핑.merging(저장된 폴백)`을 넘긴다.
   **동기화 경로와 백필 경로 모두**에서 같은 맵을 써야 한다 — 같은 이벤트가
   경로에 따라 다르게 채점되면 안 된다.

- [ ] **Step 0: 테스트 헬퍼에 store·changelogSource 주입 추가**

`Tests/ArcadeAppTests/TestSupport.swift`의 `makeModel`은 store를 내부에서 만들어
테스트가 미리 상태를 심을 수 없고, 백필 소스를 바꿔 끼울 수도 없다. 둘 다
주입 가능하게 한다. **기본값을 주어 기존 호출부는 그대로 컴파일된다.**

```swift
func makeModel(
    store: ArcadeStore? = nil,
    changelogSource: (any ChangelogSource)? = nil,
    credentials: InMemoryCredentialStore = InMemoryCredentialStore(),
    ...
) throws -> AppModel {
    ...
    return AppModel(
        store: try store ?? ArcadeStore(container: ArcadeStore.makeInMemoryContainer()),
        ...
        changelogSourceFactory: changelogSource.map { source in { _ in source } },
```

`AppModel`에도 대응 파라미터를 넣는다. `clientFactory`와 같은 패턴이다 —
프로덕션은 기본값으로 실제 구현을 쓰고, 테스트만 갈아 끼운다:

```swift
    private let changelogSourceFactory: (JiraClient) -> any ChangelogSource

    public init(
        ...,
        changelogSourceFactory: ((JiraClient) -> any ChangelogSource)? = nil
    ) {
        self.changelogSourceFactory =
            changelogSourceFactory ?? { JiraChangelogSource(client: $0) }
```

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS — 기존 테스트가 하나도 깨지지 않아야 한다.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/ArcadeAppTests/BackfillIntegrationTests.swift`:

```swift
import Testing
import Foundation
import ArcadeCore
import JiraKit
@testable import ArcadeApp

/// 스크립트대로 응답하는 백필 소스. 어떤 토큰으로 요청받았는지 기록한다.
@MainActor
private final class StubChangelogSource: ChangelogSource {
    var pages: [(issues: [JiraIssueWithChangelog], nextPageToken: String?)]
    var catalog: [JiraStatusCatalogEntry]
    private(set) var requestedTokens: [String?] = []
    /// 이 토큰을 요청받으면 던진다. 중단·실패 시나리오에 쓴다.
    var failOnToken: String??

    init(pages: [(issues: [JiraIssueWithChangelog], nextPageToken: String?)],
         catalog: [JiraStatusCatalogEntry] = []) {
        self.pages = pages
        self.catalog = catalog
    }

    func fetchPage(jql: String, pageToken: String?)
        async throws -> (issues: [JiraIssueWithChangelog], nextPageToken: String?) {
        requestedTokens.append(pageToken)
        if let failOnToken, failOnToken == pageToken { throw StubError() }
        guard !pages.isEmpty else { return ([], nil) }
        return pages.removeFirst()
    }

    func fetchIssueChangelog(key: String, startAt: Int) async throws -> JiraChangelogPage {
        JiraChangelogPage(startAt: 0, maxResults: 100, total: 0, histories: [])
    }

    func fetchStatusCatalog() async throws -> [JiraStatusCatalogEntry] { catalog }
}

private func backfillIssue(
    key: String, historyId: String, at: Date, author: String,
    fromId: String = "10009", from: String = "To Do",
    toId: String = "10016", to: String = "In Progress"
) -> JiraIssueWithChangelog {
    JiraIssueWithChangelog(
        key: key, createdAt: at.addingTimeInterval(-days(30)), dueDate: nil,
        changelog: JiraChangelogPage(startAt: 0, maxResults: 10, total: 1, histories: [
            JiraChangelogHistory(
                id: historyId, createdAt: at, authorAccountId: author,
                items: [JiraChangelogItem(field: "status", fromId: fromId, fromString: from,
                                          toId: toId, toString: to)]
            )
        ])
    )
}

/// 백필이 이벤트를 실제로 저장하고 진행률을 보고한 뒤 지운다.
@MainActor
@Test func backfillStoresEventsAndClearsProgress() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = StubChangelogSource(pages: [
        ([backfillIssue(key: "MPT-1", historyId: "1",
                        at: iso("2026-08-01T00:00:00Z"), author: "acc-me")], nil)
    ])
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: [
        "To Do": .backlog, "In Progress": .active,
    ]))
    let model = try makeModel(store: store, changelogSource: source, workflow: workflow)
    await model.start()

    await model.startBackfill()

    #expect(try store.loadEvents().count == 1, "백필이 이벤트를 넣어야 한다")
    #expect(model.backfillProgress == nil, "끝나면 진행 바가 사라진다")
    #expect(model.hasResumableBackfill == false, "정상 종료된 백필은 재개 대상이 아니다")
}

/// **이 배선의 존재 이유.** 매핑에 없는 상태가 폴백으로 해석돼 저장되고,
/// 그 덕에 XP가 0이 아니게 된다.
@MainActor
@Test func fallbackMappingIsStoredAndReachesScoring() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    // "Merged to Staging"은 사용자 매핑에 없다. 카탈로그의 statusCategory로만 해석된다.
    let source = StubChangelogSource(
        pages: [([backfillIssue(key: "MPT-1", historyId: "1",
                                at: iso("2026-08-01T00:00:00Z"), author: "acc-me",
                                fromId: "10009", from: "To Do",
                                toId: "10071", to: "Merged to Staging")], nil)],
        catalog: [
            JiraStatusCatalogEntry(id: "10009", name: "To Do", categoryKey: "new"),
            JiraStatusCatalogEntry(id: "10071", name: "Merged to Staging",
                                   categoryKey: "indeterminate"),
        ]
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    let model = try makeModel(store: store, changelogSource: source, workflow: workflow)
    await model.start()

    await model.startBackfill()

    #expect(try workflow.loadFallbacks()?.statusToStage == ["Merged to Staging": .active],
            "폴백 매핑이 저장돼야 다음 재집계에서도 쓸 수 있다")
    let lifetime = try #require(model.lifetimeSummary)
    #expect(lifetime.totalXP > 0,
            "backlog -> active 전진이므로 폴백이 채점에 닿았다면 XP가 붙는다")
}

/// 저장된 폴백은 덮이지 않고 쌓인다. 덮어쓰면 이전 실행이 해석한 매핑이 사라진다.
@MainActor
@Test func newFallbacksMergeWithStoredOnes() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: ["To Do": .backlog]))
    try workflow.saveFallbacks(WorkflowMap(statusToStage: ["QA Passed": .verify]))

    let source = StubChangelogSource(
        pages: [([backfillIssue(key: "MPT-1", historyId: "1",
                                at: iso("2026-08-01T00:00:00Z"), author: "acc-me",
                                toId: "10071", to: "Merged to Staging")], nil)],
        catalog: [JiraStatusCatalogEntry(id: "10071", name: "Merged to Staging",
                                         categoryKey: "indeterminate")]
    )
    let model = try makeModel(store: store, changelogSource: source, workflow: workflow)
    await model.start()

    await model.startBackfill()

    let stored = try #require(try workflow.loadFallbacks()).statusToStage
    #expect(stored["QA Passed"] == .verify, "이전 폴백이 살아 있어야 한다")
    #expect(stored["Merged to Staging"] == .active)
}

/// 사용자 매핑이 폴백을 이긴다 — 마법사에서 지정한 값이 추정값에 덮이면 안 된다.
@MainActor
@Test func userMappingWinsOverStoredFallbackWhenScoring() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let event = DomainEvent(
        issueKey: "MPT-1", kind: .statusChanged,
        fromStatus: "In Progress", toStatus: "Merged to Staging",
        observedAt: iso("2026-08-10T00:00:00Z"), actorAccountId: "acc-me",
        priorUpdatedAt: iso("2026-08-01T00:00:00Z")
    )
    _ = try store.appendBackfillEvents([event], historyIds: ["h-1"])

    // 사용자는 review로 지정했는데 폴백은 active로 추정했다.
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: [
        "In Progress": .active, "Merged to Staging": .review,
    ]))
    try workflow.saveFallbacks(WorkflowMap(statusToStage: ["Merged to Staging": .active]))

    let model = try makeModel(store: store, workflow: workflow)
    await model.start()

    // 사용자 매핑(review, order 2)이 이기면 active(order 1)에서의 전진이라 XP가 붙는다.
    // 폴백이 이기면 active -> active 수평 이동이라 0점이다.
    let lifetime = try #require(model.lifetimeSummary)
    #expect(lifetime.totalXP > 0, "사용자 매핑이 이겨야 전진으로 채점된다")
}

/// 중단해도 이미 넣은 이벤트는 남고, 재개 지점이 저장돼 "이어서"가 뜬다.
/// 롤백하지 않는 것이 설계다 — 이벤트 로그는 append-only다(스펙 §7.2).
@MainActor
@Test func failureKeepsStoredEventsAndLeavesAResumePoint() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = StubChangelogSource(pages: [
        ([backfillIssue(key: "MPT-1", historyId: "1",
                        at: iso("2026-08-01T00:00:00Z"), author: "acc-me")], "tok-2"),
    ])
    source.failOnToken = .some("tok-2")   // 두 번째 페이지에서 실패
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: [
        "To Do": .backlog, "In Progress": .active,
    ]))
    let model = try makeModel(store: store, changelogSource: source, workflow: workflow)
    await model.start()

    await model.startBackfill()

    #expect(try store.loadEvents().count == 1, "실패해도 첫 페이지 결과는 남는다")
    #expect(model.hasResumableBackfill, "중단 지점이 남아 이어받을 수 있어야 한다")
    let snapshot = try #require(try store.resumableBackfill())
    #expect(snapshot.nextPageToken == "tok-2")
}

/// 재개는 저장된 토큰부터 요청한다. 처음부터 다시 훑으면 왕복 시간이 통째로 낭비된다.
@MainActor
@Test func resumeRequestsTheStoredToken() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let runId = try store.beginBackfill(jql: "assignee = currentUser()",
                                        at: iso("2026-08-13T00:00:00Z"), totalIssueCount: 200)
    try store.advanceBackfill(runId, nextPageToken: "tok-9", processedIssueCount: 100,
                              discovered: [], partiallyRestored: [])

    let source = StubChangelogSource(pages: [([], nil)])
    let model = try makeModel(store: store, changelogSource: source)
    await model.start()

    await model.resumeBackfillIfAvailable()

    #expect(source.requestedTokens == ["tok-9"])
}

/// 재개할 것이 없으면 아무 일도 하지 않는다 — 요청조차 나가지 않아야 한다.
@MainActor
@Test func resumeWithNothingStoredDoesNothing() async throws {
    let source = StubChangelogSource(pages: [([], nil)])
    let model = try makeModel(changelogSource: source)
    await model.start()

    await model.resumeBackfillIfAvailable()

    #expect(source.requestedTokens.isEmpty)
}

/// 백필이 돌고 있으면 두 번째 시작은 무시된다 — 같은 페이지를 두 곳에서 훑으면
/// 진행률 카운터가 뒤엉킨다(이벤트 중복은 historyId가 막지만 카운터는 못 막는다).
@MainActor
@Test func startingTwiceRunsOnlyOnce() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = StubChangelogSource(pages: [
        ([backfillIssue(key: "MPT-1", historyId: "1",
                        at: iso("2026-08-01T00:00:00Z"), author: "acc-me")], nil)
    ])
    let model = try makeModel(store: store, changelogSource: source)
    await model.start()

    async let first: Void = model.startBackfill()
    async let second: Void = model.startBackfill()
    _ = await (first, second)

    #expect(source.requestedTokens.count == 1, "페이지 요청이 한 번만 나가야 한다")
}

/// 시즌은 통산의 부분집합이다. 시즌 밖 이벤트가 있으면 시즌 XP는 통산보다 **엄격히** 작아야
/// 한다 — `<=`로 검사하면 둘 다 0일 때도 통과해 아무것도 검증하지 못한다(스펙 §6).
@MainActor
@Test func seasonSummaryIsStrictlySmallerWhenOldEventsExist() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let now = iso("2026-08-14T09:00:00Z")
    let old = DomainEvent(
        issueKey: "MPT-1", kind: .statusChanged, fromStatus: "To Do", toStatus: "In Progress",
        observedAt: iso("2026-01-05T00:00:00Z"), actorAccountId: "acc-me",
        priorUpdatedAt: iso("2025-12-15T00:00:00Z")
    )
    let recent = DomainEvent(
        issueKey: "MPT-2", kind: .statusChanged, fromStatus: "To Do", toStatus: "In Progress",
        observedAt: iso("2026-08-10T00:00:00Z"), actorAccountId: "acc-me",
        priorUpdatedAt: iso("2026-07-20T00:00:00Z")
    )
    _ = try store.appendBackfillEvents([old, recent], historyIds: ["h-old", "h-recent"])

    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: [
        "To Do": .backlog, "In Progress": .active,
    ]))
    let model = try makeModel(store: store, workflow: workflow, now: now)

    await model.start()

    let lifetime = try #require(model.lifetimeSummary)
    let season = try #require(model.seasonSummary)
    #expect(lifetime.totalXP > 0, "이벤트가 있으므로 통산 XP가 0이면 집계가 안 된 것이다")
    #expect(season.totalXP > 0, "시즌 안 이벤트가 있으므로 시즌 XP도 0이 아니다")
    #expect(season.totalXP < lifetime.totalXP, "시즌 밖 이벤트가 통산에만 잡혀야 한다")
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter Backfill`
Expected: FAIL — `value of type 'AppModel' has no member 'startBackfill'`

- [ ] **Step 3: `AppModel`에 상태와 메서드 추가**

프로퍼티 선언부에:

```swift
    /// 백필 진행률. 실행 중일 때만 값이 있다.
    public struct BackfillProgress: Sendable, Equatable {
        public let processed: Int
        /// 총계를 모르면 nil이다. 새 검색 API는 total을 주지 않으므로
        /// 처리한 수를 총계로 삼으면 진행률이 늘 100%로 보인다.
        public let total: Int?
    }
    public private(set) var backfillProgress: BackfillProgress?
    /// 전체 이력 기준 요약. 프로필에 표시한다.
    public private(set) var lifetimeSummary: PlayerSummary?
    /// 최근 `RuleSet.seasonDays`일 기준 요약. HUD의 XP 바가 이 값을 쓴다.
    public private(set) var seasonSummary: PlayerSummary?
    /// 중단된 백필이 남아 있는지. 설정 화면이 "이어서 불러오기"를 보여줄 근거다.
    public private(set) var hasResumableBackfill: Bool = false
    /// 로그인한 계정. "내가 직접 옮긴 것만 XP" 판정에 쓴다.
    public private(set) var myAccountId: String?
```

`validate()`가 `me`를 얻는 지점에서 `myAccountId = me.accountId`를 저장한다.
`start()`와 백필 종료 시점에 `hasResumableBackfill`을 갱신한다.

**실효 맵 헬퍼**를 추가하고, `ScoreEngine`/`SyncEngine`을 만드는 **모든 지점**에서 쓴다:

```swift
    /// 사용자 매핑에 백필이 추정한 폴백을 밑에 깔아 만든 채점용 맵.
    ///
    /// 동기화 경로와 백필 경로가 **같은 맵**을 써야 한다 — 다르면 같은 이벤트가
    /// 어느 경로로 집계됐는지에 따라 다른 XP를 받는다.
    ///
    /// 폴백 로드가 실패하면 빈 폴백으로 진행한다. 추정값이므로 앱을 막을 이유가 없다
    /// (사용자 매핑의 로드 실패는 지금처럼 별도로 다룬다).
    private func effectiveWorkflow() -> WorkflowMap {
        let base = (try? workflow.load()) ?? WorkflowMap(statusToStage: [:])
        let fallbacks = (try? workflow.loadFallbacks())?.statusToStage ?? [:]
        return base.merging(fallbacks)
    }
```

메서드를 추가한다:

```swift
    /// 실행 중인 백필. 중단하려면 이걸 취소한다.
    private var backfillTask: Task<Void, Never>?

    /// 과거 기록을 불러온다. 사용자가 설정에서 눌러 시작한다 — 자동 실행하지 않는다.
    public func startBackfill() async {
        await launchBackfill(resume: false)
    }

    /// 중단된 백필이 있으면 이어서 진행한다. 없으면 아무 일도 하지 않는다 —
    /// 요청조차 나가지 않아야 한다.
    public func resumeBackfillIfAvailable() async {
        guard (try? store.resumableBackfill()) != nil else { return }
        await launchBackfill(resume: true)
    }

    /// 실행 중인 백필을 중단한다. 이미 넣은 이벤트는 그대로 유효하고, 중단 지점의
    /// `nextPageToken`이 저장돼 있어 나중에 "이어서 불러오기"로 재개된다.
    public func cancelBackfill() {
        backfillTask?.cancel()
    }

    private func launchBackfill(resume: Bool) async {
        // 이미 돌고 있으면 두 번 시작하지 않는다 — 같은 페이지를 두 곳에서 훑으면
        // 진행률이 뒤엉킨다(이벤트 중복은 historyId가 막지만 카운터는 못 막는다).
        guard backfillTask == nil else { return }
        let task = Task { await runBackfill(resume: resume) }
        backfillTask = task
        await task.value
        backfillTask = nil
    }

    private func runBackfill(resume: Bool) async {
        guard let client else { return }
        let jql = "assignee = currentUser()"

        // 진행 상태 저장(begin/advance/finish)은 엔진이 직접 한다 — 페이지 경계마다
        // 저장해야 하는데 여기서는 루프 안을 볼 수 없다. 여기서 또 부르면 이중 기록이 된다.
        let engine = BackfillEngine(
            source: changelogSourceFactory(client),
            store: store,
            workflow: effectiveWorkflow()
        )

        do {
            let outcome = try await engine.run(
                jql: jql, now: clock(), resume: resume
            ) { [weak self] processed, total in
                self?.backfillProgress = BackfillProgress(processed: processed, total: total)
            }
            persistFallbacks(outcome.resolvedFallbacks)
        } catch {
            // 실패·중단해도 여기까지 넣은 이벤트는 유효하고 진행 지점이 저장돼 있다.
            // run을 미완료로 남겨 "이어서 불러오기"가 뜨게 하는 것이 의도된 동작이다.
        }

        backfillProgress = nil
        hasResumableBackfill = (try? store.resumableBackfill()) != nil
        await refreshSummaries()
    }

    /// 새로 해석한 폴백을 기존 것과 **병합해** 저장한다. 덮어쓰면 이전 실행이
    /// 해석한 매핑이 사라진다 — 범위를 좁혀 다시 돌리면 폴백이 줄어드는 셈이다.
    private func persistFallbacks(_ discovered: [String: Stage]) {
        guard !discovered.isEmpty else { return }
        var merged = (try? workflow.loadFallbacks())?.statusToStage ?? [:]
        for (name, stage) in discovered { merged[name] = stage }
        try? workflow.saveFallbacks(WorkflowMap(statusToStage: merged))
    }

    /// 통산과 시즌을 각각 집계한다. 같은 이벤트 로그를 두 범위로 읽을 뿐이다.
    private func refreshSummaries() async {
        guard let events = try? store.loadEvents(),
              let mirror = try? store.loadMirror() else { return }
        let now = clock()
        let engine = ScoreEngine(
            rules: rules, workflow: effectiveWorkflow(),
            calendar: calendar, myAccountId: myAccountId
        )
        lifetimeSummary = engine.recompute(events: events, issues: mirror, now: now).summary
        let seasonStart = now.addingTimeInterval(-Double(rules.seasonDays) * 86_400)
        seasonSummary = engine.recompute(events: events, issues: mirror, now: now,
                                         since: seasonStart).summary
    }
```

> 기존에 `SyncEngine`을 만드는 지점(`workflow: map`을 넘기는 곳)도 `effectiveWorkflow()`를
> 쓰도록 바꾼다. 무엇을 바꿨는지 리포트에 적는다.
>
> `start()` 끝에서 `refreshSummaries()`를 불러 로그인 직후에도 요약이 채워지게 한다 —
> 백필을 돌리지 않은 사용자도 기존 이벤트로 집계된 값을 봐야 한다.

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift \
        Packages/Jirarcade/Tests/ArcadeAppTests/TestSupport.swift \
        Packages/Jirarcade/Tests/ArcadeAppTests/BackfillIntegrationTests.swift
git commit -m "feat: 백필 실행·재개 배선과 폴백을 반영한 시즌·통산 집계"
```

---

### Task 13: UI — 백필 버튼·진행 바·시즌 XP

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/SettingsView.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/ArcadeFloorView.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/ModuleBoundaryTests.swift` (기존 검사가 새 파일도 훑는지 확인)

**Interfaces:**
- Consumes: `AppModel.backfillProgress`·`startBackfill()`·`seasonSummary`·`lifetimeSummary` (Task 12)
- Produces: 없음 (화면)

- [ ] **Step 1: 설정에 백필 버튼 추가**

`SettingsView.swift`의 적당한 섹션에 넣는다. 색은 반드시 `theme.*`를 쓴다:

```swift
            VStack(alignment: .leading, spacing: 8) {
                Text("과거 기록")
                    .font(.headline)
                    .foregroundStyle(theme.inkPrimary)
                Text("Jira 변경 이력을 읽어 지난 전이를 점수에 반영합니다. 내가 직접 옮긴 전이만 XP가 됩니다.")
                    .font(.callout)
                    .foregroundStyle(theme.inkSecondary)

                if let progress = model.backfillProgress {
                    // 총계를 모를 수 있다 — 새 검색 API는 total을 주지 않는다.
                    // 그때는 불확정 바를 쓴다. 처리한 수를 총계로 삼으면 늘 100%로 보인다.
                    if let total = progress.total, total > 0 {
                        ProgressView(value: Double(min(progress.processed, total)),
                                     total: Double(total)) {
                            Text("불러오는 중 \(progress.processed)/\(total)")
                                .font(.caption)
                                .foregroundStyle(theme.inkSecondary)
                        }
                        .tint(theme.accent)
                    } else {
                        ProgressView {
                            Text("불러오는 중 \(progress.processed)건")
                                .font(.caption)
                                .foregroundStyle(theme.inkSecondary)
                        }
                        .tint(theme.accent)
                    }
                    Button("중단") { model.cancelBackfill() }
                    Text("중단해도 지금까지 불러온 기록은 남고, 나중에 이어서 받을 수 있습니다.")
                        .font(.caption2)
                        .foregroundStyle(theme.inkTertiary)
                } else if model.hasResumableBackfill {
                    Button("이어서 불러오기") {
                        Task { await model.resumeBackfillIfAvailable() }
                    }
                } else {
                    Button("과거 기록 불러오기") {
                        Task { await model.startBackfill() }
                    }
                }
            }
```

- [ ] **Step 2: 아케이드 플로어에 진행 바와 시즌 XP 표시**

`ArcadeFloorView.swift`의 상태 표시 영역에 넣는다:

```swift
            if let progress = model.backfillProgress {
                HStack(spacing: 8) {
                    if let total = progress.total, total > 0 {
                        ProgressView(value: Double(min(progress.processed, total)),
                                     total: Double(total))
                            .tint(theme.accent)
                            .frame(width: 120)
                        Text("과거 기록 \(progress.processed)/\(total)")
                            .font(.caption)
                            .foregroundStyle(theme.inkSecondary)
                    } else {
                        ProgressView()
                            .tint(theme.accent)
                            .frame(width: 120)
                        Text("과거 기록 \(progress.processed)건")
                            .font(.caption)
                            .foregroundStyle(theme.inkSecondary)
                    }
                }
            }

            if let season = model.seasonSummary, let lifetime = model.lifetimeSummary {
                HStack(spacing: 12) {
                    // HUD는 시즌을 보여준다 — 오늘 하나 처리한 것이 움직여야 하기 때문이다.
                    Text("시즌 LV.\(season.level)")
                        .font(.callout.bold())
                        .foregroundStyle(theme.accent)
                    ProgressView(value: Double(season.xpIntoLevel),
                                 total: Double(max(season.xpForNextLevel, 1)))
                        .tint(theme.accent)
                        .frame(width: 140)
                    // 통산은 옆에 조용히 둔다.
                    Text("통산 LV.\(lifetime.level)")
                        .font(.caption)
                        .foregroundStyle(theme.inkTertiary)
                }
            }
```

- [ ] **Step 3: 색 리터럴 검사 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter ModuleBoundary`
Expected: PASS — 새 코드에 색 리터럴이 없어야 한다. 실패하면 해당 색을 `theme` 토큰으로 바꾼다.

- [ ] **Step 4: 전체 테스트**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS, 경고 0

- [ ] **Step 5: 앱을 실제로 띄워 눈으로 확인**

```bash
cd /Users/bahn/personal/jirarcade && ./scripts/make-app.sh --open
```

확인할 것: 설정에 "과거 기록 불러오기" 버튼이 보이는가, 눌렀을 때 진행 바가 나타나는가, 끝나면 사라지는가, 아케이드 플로어에 시즌/통산 레벨이 함께 보이는가. **결과를 리포트에 적는다** — 렌더링은 테스트가 잡지 못하는 영역이다.

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeUI/SettingsView.swift \
        Packages/Jirarcade/Sources/ArcadeUI/ArcadeFloorView.swift
git commit -m "feat: 백필 버튼·진행 바와 시즌/통산 레벨 표시"
```

---

### Task 14: 미매핑 상태를 매핑 마법사 후보로

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/WorkflowMappingView.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/BackfillIntegrationTests.swift`

**Interfaces:**
- Consumes: `ArcadeStore.resumableBackfill()`·`BackfillRun.discoveredUnmappedStatuses` (Task 10)
- Produces: `AppModel.historyDiscoveredStatuses: [String]`

- [ ] **Step 1: 실패하는 테스트를 `BackfillIntegrationTests.swift` 끝에 추가**

```swift
/// 백필이 발견한 과거 상태가 앱을 다시 켜도 남아 매핑 후보로 올라온다.
/// 사용자가 확정하면 재집계로 소급 XP가 정확해진다 — 이벤트가 원본이고 점수는 파생이다(스펙 §5).
@MainActor
@Test func historyDiscoveredStatusesRestoreOnLaunch() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let runId = try store.beginBackfill(jql: "q", at: iso("2026-08-13T09:00:00Z"),
                                        totalIssueCount: 100)
    try store.advanceBackfill(runId, nextPageToken: "tok", processedIssueCount: 40,
                              discovered: ["Merged to Staging", "QA Done"], partiallyRestored: [])

    let model = try makeModel(store: store)

    await model.start()

    #expect(Set(model.historyDiscoveredStatuses) == ["Merged to Staging", "QA Done"])
    #expect(model.hasResumableBackfill == true, "중단된 백필이 있으면 이어받기를 제안해야 한다")
}

/// **정상 종료된** 백필의 발견 목록도 남아야 한다. `resumableBackfill()`은 미완료 run만
/// 보므로 그것만 읽으면 백필이 끝나는 순간 매핑 후보가 통째로 사라진다 —
/// 정작 매핑이 필요한 시점은 백필이 끝난 뒤다.
@MainActor
@Test func discoveriesSurviveAFinishedBackfill() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let runId = try store.beginBackfill(jql: "q", at: iso("2026-08-13T09:00:00Z"),
                                        totalIssueCount: 100)
    try store.advanceBackfill(runId, nextPageToken: nil, processedIssueCount: 100,
                              discovered: ["Merged to Staging"], partiallyRestored: [])
    try store.finishBackfill(runId, at: iso("2026-08-13T09:30:00Z"), failure: nil)

    let model = try makeModel(store: store)
    await model.start()

    #expect(model.historyDiscoveredStatuses == ["Merged to Staging"])
    #expect(model.hasResumableBackfill == false, "끝난 백필은 이어받기 대상이 아니다")
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter historyDiscoveredStatuses`
Expected: FAIL — `value of type 'AppModel' has no member 'historyDiscoveredStatuses'`

- [ ] **Step 3: `AppModel`에 프로퍼티 추가**

```swift
    /// 백필이 과거 이력에서 발견한, 현재 매핑에 없는 상태명.
    /// 매핑 마법사가 이 목록을 후보에 더해 보여준다.
    public private(set) var historyDiscoveredStatuses: [String] = []
```

**`ArcadeStore`에 조회 하나를 추가한다.** `resumableBackfill()`은 미완료 run만 보므로
그것만 읽으면 백필이 정상 종료되는 순간 매핑 후보가 사라진다 — 정작 매핑이 필요한
시점은 백필이 끝난 뒤다:

```swift
    /// 가장 최근 백필이 발견한 미매핑 상태명. **완료 여부와 무관하게** 마지막 run을 본다.
    /// 끝난 백필의 발견 목록도 매핑 후보로 남아야 하기 때문이다.
    public func lastDiscoveredStatuses() throws -> [String] {
        var descriptor = FetchDescriptor<BackfillRun>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.discoveredUnmappedStatuses ?? []
    }
```

`runBackfill`의 마지막(진행 바를 지우고 요약을 갱신하는 자리)에서 채운다:

```swift
            historyDiscoveredStatuses = outcome.discoveredStatuses
```

성공·실패 어느 쪽이든 저장소에서도 복원한다. `start()`와 백필 종료 지점 모두에서:

```swift
        historyDiscoveredStatuses = (try? store.lastDiscoveredStatuses()) ?? []
```

> 백필이 예외로 끝나면 `outcome`이 없으므로 저장소 경로가 유일한 출처다.
> 엔진이 페이지마다 `advanceBackfill`로 저장해 두었으므로 중단 시점까지의 발견은 남아 있다.

- [ ] **Step 4: 매핑 마법사에 후보를 더한다**

`WorkflowMappingView.swift`에서 후보 목록을 만드는 곳에 병합한다:

```swift
    /// 현재 미Done 티켓에서 본 상태 + 백필이 과거 이력에서 발견한 상태.
    /// 후자에는 표시를 달아 "지금은 안 쓰지만 과거에 있던 상태"임을 알린다.
    private var allCandidates: [(name: String, fromHistory: Bool)] {
        let current = Set(candidates)
        let historical = Set(model.historyDiscoveredStatuses).subtracting(current)
        return current.sorted().map { ($0, false) }
             + historical.sorted().map { ($0, true) }
    }
```

각 행에 `fromHistory`면 캡션을 붙인다:

```swift
                    if entry.fromHistory {
                        Text("과거 이력에서 발견")
                            .font(.caption2)
                            .foregroundStyle(theme.inkTertiary)
                    }
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS, 경고 0

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Store/ArcadeStore.swift \
        Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift \
        Packages/Jirarcade/Sources/ArcadeUI/WorkflowMappingView.swift \
        Packages/Jirarcade/Tests/ArcadeAppTests/BackfillIntegrationTests.swift
git commit -m "feat: 백필이 발견한 과거 상태를 매핑 마법사 후보로 제출"
```

---

### Task 15: 불변식 검증 — 채점은 이벤트 로그만의 함수

**Files:**
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/BackfillInvariantTests.swift`

**Interfaces:**
- Consumes: 전 태스크
- Produces: 없음 (검증 전용)

- [ ] **Step 1: 불변식 테스트 작성**

```swift
import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

private var utc: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private func backfilledEvents() -> [DomainEvent] {
    let issue = JiraIssueWithChangelog(
        key: "MPT-1", createdAt: iso("2023-01-01T00:00:00Z"),
        dueDate: iso("2023-03-01T00:00:00Z"),
        changelog: JiraChangelogPage(startAt: 0, maxResults: 100, total: 2, histories: [
            JiraChangelogHistory(id: "1", createdAt: iso("2023-02-01T00:00:00Z"),
                                 authorAccountId: "acc-me",
                                 items: [JiraChangelogItem(field: "status", fromId: "1",
                                                           fromString: "To Do", toId: "2",
                                                           toString: "In Progress")]),
            JiraChangelogHistory(id: "2", createdAt: iso("2023-02-20T00:00:00Z"),
                                 authorAccountId: "acc-me",
                                 items: [JiraChangelogItem(field: "status", fromId: "2",
                                                           fromString: "In Progress", toId: "3",
                                                           toString: "In Review")]),
        ])
    )
    return ChangelogParser().parse(issue: issue).map(\.event)
}

/// 계획 1 최종 리뷰에서 확립된 불변식: 채점은 (이벤트 로그, RuleSet)만의 함수다.
/// 백필 이벤트도 이를 지켜야 한다 — 미러를 비워도 XP가 같아야 한다(스펙 §4.3).
@Test func backfillScoresDoNotDependOnTheMirror() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc,
                             myAccountId: "acc-me")
    let events = backfilledEvents()
    let now = iso("2026-08-13T00:00:00Z")

    let withMirror = engine.recompute(
        events: events,
        issues: ["MPT-1": ObservedIssue(
            key: "MPT-1", summary: "s", statusName: "In Review", issueType: "개선",
            priority: nil, assigneeAccountId: "acc-me", assigneeName: nil,
            dueDate: iso("2099-01-01T00:00:00Z"),   // 미러의 마감일을 극단적으로 바꾼다
            jiraUpdatedAt: now                       // 미러의 갱신 시각도 오늘로 덮는다
        )],
        now: now
    )
    let withoutMirror = engine.recompute(events: events, issues: [:], now: now)

    #expect(withMirror.summary.totalXP == withoutMirror.summary.totalXP,
            "미러가 점수를 바꾸면 재집계가 미러 상태에 오염된다")
    #expect(withMirror.scored.map(\.xp) == withoutMirror.scored.map(\.xp))
}

/// 백필 이벤트의 재집계도 멱등이다.
@Test func backfillRecomputeIsIdempotent() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc,
                             myAccountId: "acc-me")
    let now = iso("2026-08-13T00:00:00Z")
    let first = engine.recompute(events: backfilledEvents(), issues: [:], now: now)
    let second = engine.recompute(events: backfilledEvents(), issues: [:], now: now)
    #expect(first.summary == second.summary)
}

/// 시즌은 **범위만** 자르고 채점 규칙은 바꾸지 않는다. 같은 이벤트는 통산과 시즌에서
/// 같은 XP를 받아야 한다 — 사용자가 두 숫자를 나란히 보므로 어긋나면 즉시 드러난다.
///
/// 이 불변식은 `statusEnteredAt` 재구성이 두 호출에서 공유되기 때문에 성립한다. 시즌 필터를
/// 정렬 직후에 적용하도록 바꾸면 시즌 안 첫 전이의 정체일이 0으로 리셋되어 조용히 깨진다.
@Test func sameEventScoresIdenticallyInSeasonAndLifetime() throws {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc,
                             myAccountId: "acc-me")
    let now = iso("2026-08-20T00:00:00Z")
    let events = [
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged,
                    fromStatus: "To Do", toStatus: "In Progress",
                    observedAt: iso("2026-02-01T00:00:00Z"), actorAccountId: "acc-me",
                    priorUpdatedAt: iso("2026-01-11T00:00:00Z")),
        DomainEvent(issueKey: "DEMO-2", kind: .statusChanged,
                    fromStatus: "To Do", toStatus: "In Progress",
                    observedAt: iso("2026-08-15T00:00:00Z"), actorAccountId: "acc-me",
                    priorUpdatedAt: iso("2026-07-25T00:00:00Z")),
    ]

    let lifetime = engine.recompute(events: events, issues: [:], now: now)
    let season = engine.recompute(events: events, issues: [:], now: now,
                                  since: iso("2026-07-21T00:00:00Z"))

    let inLifetime = try #require(lifetime.scored.first { $0.event.issueKey == "DEMO-2" }?.xp)
    let inSeason = try #require(season.scored.first { $0.event.issueKey == "DEMO-2" }?.xp)
    #expect(inLifetime == inSeason,
            "시즌은 범위를 자를 뿐이다 — 같은 이벤트의 XP가 달라지면 statusEnteredAt이 공유되지 않은 것이다")
    #expect(inSeason > 0, "0끼리 비교하면 아무것도 검증하지 못한다")
}

/// 남이 옮긴 전이가 섞여도 statusEnteredAt은 갱신된다 — 정체일이 부풀지 않는다(스펙 §4.2).
@Test func othersTransitionsStillAdvanceTheStagnationBaseline() throws {
    let issue = JiraIssueWithChangelog(
        key: "MPT-1", createdAt: iso("2023-01-01T00:00:00Z"), dueDate: nil,
        changelog: JiraChangelogPage(startAt: 0, maxResults: 100, total: 2, histories: [
            JiraChangelogHistory(id: "1", createdAt: iso("2023-02-01T00:00:00Z"),
                                 authorAccountId: "acc-other",
                                 items: [JiraChangelogItem(field: "status", fromId: "1",
                                                           fromString: "To Do", toId: "2",
                                                           toString: "In Progress")]),
            JiraChangelogHistory(id: "2", createdAt: iso("2023-02-08T00:00:00Z"),
                                 authorAccountId: "acc-me",
                                 items: [JiraChangelogItem(field: "status", fromId: "2",
                                                           fromString: "In Progress", toId: "3",
                                                           toString: "In Review")]),
        ])
    )
    let events = ChangelogParser().parse(issue: issue).map(\.event)
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc,
                             myAccountId: "acc-me")
    let result = engine.recompute(events: events, issues: [:],
                                  now: iso("2026-08-13T00:00:00Z"))

    #expect(result.scored.count == 2)
    let others = try #require(result.scored.first)
    let mine = try #require(result.scored.dropFirst().first)
    #expect(others.xp == 0, "남이 옮긴 전이는 기록하되 점수를 주지 않는다")
    #expect(mine.xp > 0)

    // "기준선이 전진한다"를 상수로 확인하면 RuleSet이 바뀔 때 의미가 흔들린다.
    // 남의 전이를 뺀 채로 한 번 더 채점해 직접 비교한다 — 그쪽은 정체가 7일이 아니라
    // 38일로 계산되므로 XP가 더 커야 한다. 그 차이가 곧 이 불변식의 내용이다.
    let withoutOthers = events.filter { $0.actorAccountId == "acc-me" }
    let inflated = engine.recompute(events: withoutOthers, issues: [:],
                                    now: iso("2026-08-13T00:00:00Z"))
    let inflatedXP = try #require(inflated.scored.first).xp
    #expect(inflatedXP > mine.xp,
            "남의 전이를 버리면 정체가 38일로 부풀어 XP가 커진다 — 그래서 기록은 남겨야 한다")
}

/// 백필을 두 번 돌려도 XP가 두 배가 되지 않는다. 이 계획의 핵심 약속이고,
/// historyId 중복 검사가 그것을 지킨다. 이벤트 수만 보는 검사(Task 11)와 달리
/// **점수 층위에서** 고정한다 — 사용자가 실제로 보는 값이 그쪽이기 때문이다.
@MainActor
@Test func runningBackfillTwiceDoesNotDoubleXP() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc,
                             myAccountId: "acc-me")
    let now = iso("2026-08-13T00:00:00Z")
    let events = backfilledEvents()
    let historyIds = events.enumerated().map { "h-\($0.offset)" }

    _ = try store.appendBackfillEvents(events, historyIds: historyIds)
    let after1 = engine.recompute(events: try store.loadEvents(), issues: [:], now: now)

    _ = try store.appendBackfillEvents(events, historyIds: historyIds)
    let after2 = engine.recompute(events: try store.loadEvents(), issues: [:], now: now)

    #expect(after1.summary.totalXP > 0, "0끼리 비교하면 아무것도 검증하지 못한다")
    #expect(after1.summary.totalXP == after2.summary.totalXP)
    #expect(after1.summary.level == after2.summary.level)
}
```

- [ ] **Step 2: 테스트 실행**

Run: `cd Packages/Jirarcade && swift test --filter BackfillInvariant`
Expected: PASS (3 tests)

실패하면 어느 불변식이 깨졌는지 리포트에 적고 **멈춘다** — 이 셋은 설계의 근간이므로 테스트를 완화하지 않는다.

- [ ] **Step 3: 전체 테스트와 경고 확인**

```bash
cd Packages/Jirarcade
swift build --build-tests 2>&1 | grep -i warning || echo "경고 없음"
swift test
```

Expected: 경고 없음, 전체 PASS

- [ ] **Step 4: 커밋**

```bash
git add Packages/Jirarcade/Tests/ArcadeCoreTests/BackfillInvariantTests.swift
git commit -m "test: 백필이 채점 불변식과 정체 기준선을 지키는지 검증"
```

---

## Done 조건

```
□ swift build 경고 없이 성공
□ swift test 전부 통과
□ 백필을 두 번 돌려도 이벤트가 중복되지 않는다 (sourceHistoryId)
□ 남이 옮긴 전이는 기록되지만 XP를 올리지 않는다
□ 남이 옮긴 전이도 statusEnteredAt을 갱신한다
□ 과거 상태가 statusCategory로 분류돼 0점이 아니다
□ "관측 N일차"가 백필 때문에 뛰지 않는다
□ 미러를 비워도 백필 이벤트의 XP가 같다 (채점 불변식)
□ HUD는 시즌 레벨, 프로필은 통산 레벨
□ 조직 데이터가 코드·테스트에 없다
```

마지막 두 줄은 다음으로 확인한다:

```bash
cd Packages/Jirarcade
swift test --filter "BackfillInvariant|ModuleBoundary"
rg -n "flyingdoctor|atlassian\.net" Sources/ Tests/ | grep -v "example.atlassian.net" || echo "조직 데이터 없음"
```

## 실물 검증 (구현 후)

테스트가 통과해도 **실제 1,263건 백필은 돌려봐야 안다.** 계획 Done 후 다음을 확인하고 기록한다:

1. 백필 소요 시간과 429 발생 여부
2. 실제 소급 XP와 시작 레벨 (스펙 §11 리스크 1 — 예상보다 적을 수 있다)
3. `discoveredUnmappedStatuses`에 실제로 무엇이 올라오는가
4. `partiallyRestoredKeys`가 비었는가 (changelog 보충 조회 성공률)

## 다음 단계

**계획 2b-2** — 진행형 동기화를 changelog로 전환해 §2.1의 기준 불일치를 해소한다. `DiffEngine`에서 `statusChanged`를 떼어내고 증분 changelog 조회로 대체한다.

**계획 2c** — 프로젝트 범위 확장과 팀 판.
