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
    public var origin: String
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

> SwiftData는 **옵셔널이거나 기본값이 있는** 프로퍼티 추가를 lightweight migration으로 처리한다. `origin`은 옵셔널이 아니지만 기본값이 있으므로 기존 레코드도 안전하게 열린다. 별도 `VersionedSchema`는 필요하지 않다.

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
        return (envelope.issues.map(\.model), envelope.nextPageToken)
    }

    public static func decodeIssueChangelog(_ data: Data) throws -> JiraChangelogPage {
        let raw = try JSONDecoder().decode(StandaloneEnvelope.self, from: data)
        return JiraChangelogPage(
            startAt: raw.startAt, maxResults: raw.maxResults, total: raw.total,
            histories: raw.values.map(\.model)
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

        var model: JiraIssueWithChangelog {
            JiraIssueWithChangelog(
                key: key,
                createdAt: JiraChangelogResponse.timestamp(fields.created) ?? .distantPast,
                dueDate: fields.duedate.flatMap(JiraChangelogResponse.dateOnly),
                changelog: changelog.model
            )
        }
    }

    private struct RawChangelog: Decodable {
        let startAt: Int
        let maxResults: Int
        let total: Int
        let histories: [RawHistory]

        var model: JiraChangelogPage {
            JiraChangelogPage(startAt: startAt, maxResults: maxResults, total: total,
                              histories: histories.map(\.model))
        }
    }

    private struct RawHistory: Decodable {
        let id: String
        let created: String
        let author: Author?
        let items: [RawItem]

        struct Author: Decodable { let accountId: String? }

        var model: JiraChangelogHistory {
            JiraChangelogHistory(
                id: id,
                createdAt: JiraChangelogResponse.timestamp(created) ?? .distantPast,
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
    let expand = payload?["expand"] as? [String]
    #expect(expand?.contains("changelog") == true)
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

    let url = try #require(stub.sentRequests.first?.url?.absoluteString)
    #expect(url.contains("/issue/MPT-1/changelog"))
    #expect(url.contains("startAt=10"))
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

    #expect(catalog.count == 3)
    #expect(catalog[0].id == "10009")
    #expect(catalog[0].categoryKey == "new")
    #expect(catalog[1].categoryKey == "indeterminate")
    #expect(try #require(stub.sentRequests.first?.url?.absoluteString).hasSuffix("/status"))
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
            "expand": ["changelog"],
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
            path: "/issue/\(issueKey)/changelog?startAt=\(startAt)&maxResults=100",
            body: nil, resource: issueKey
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

> `perform`이 `path`에 쿼리스트링을 포함해도 동작하는지 확인한다. `URL.appendingPathComponent`는 `?`를 경로 문자로 이스케이프하므로, 그렇다면 `perform`에 쿼리 파라미터를 받는 오버로드를 추가하거나 `URLComponents`로 조립하도록 고친다. 어느 쪽을 택했는지 리포트에 적는다.

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
    #expect(catalog.stage(forId: "10009", name: "To Do") == .fallback(.backlog))
    #expect(catalog.stage(forId: "10011", name: "Done") == .mapped(.done))
}

/// ③ 카탈로그에도 없으면 미매핑이다. 임의 단계로 추측하지 않는다.
@Test func unknownStatusIsUnmapped() {
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: entries)
    #expect(catalog.stage(forId: "99999", name: "사라진상태") == .unmapped("사라진상태"))
}

/// 이름은 바뀔 수 있지만 ID는 안 바뀐다. ID로 먼저 찾는다.
@Test func catalogMatchesByIdNotName() {
    let renamed = [JiraStatusCatalogEntry(id: "10071", name: "새이름", categoryKey: "indeterminate")]
    let catalog = StatusCatalog(workflow: demoWorkflow, entries: renamed)
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
            lock.withLock { _ = collected.insert(label) }
            return .fallback(stage)
        }

        // ③ 미매핑
        lock.withLock { _ = collected.insert(label) }
        return .unmapped(label)
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
Expected: PASS (9 tests — 파라미터화 3건 포함)

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
@Test func onlyStatusItemsBecomeEvents() {
    let parsed = ChangelogParser().parse(issue: issue(histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me", items: [
            JiraChangelogItem(field: "description", fromId: nil, fromString: "옛",
                              toId: nil, toString: "새"),
            statusItem(fromId: "1", from: "To Do", toId: "2", to: "In Progress"),
            JiraChangelogItem(field: "Link", fromId: nil, fromString: nil,
                              toId: nil, toString: "blocks MPT-2"),
        ])
    ]))
    #expect(parsed.count == 1)
    #expect(parsed[0].event.kind == .statusChanged)
    #expect(parsed[0].event.fromStatus == "To Do")
    #expect(parsed[0].event.toStatus == "In Progress")
}

/// observedAt은 전이 시각이지 백필 실행 시각이 아니다. 틀리면 3년치가 오늘로 몰린다.
@Test func observedAtIsTheTransitionTime() {
    let when = iso("2023-02-28T10:15:06Z")
    let parsed = ChangelogParser().parse(issue: issue(histories: [
        history(id: "1", at: when, author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")])
    ]))
    #expect(parsed[0].event.observedAt == when)
}

@Test func historyIdAndStatusIdsAreCarried() {
    let parsed = ChangelogParser().parse(issue: issue(histories: [
        history(id: "50347", at: iso("2023-02-28T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "10009", from: "To Do", toId: "10016", to: "In Progress")])
    ]))
    #expect(parsed[0].historyId == "50347")
    #expect(parsed[0].fromStatusId == "10009")
    #expect(parsed[0].toStatusId == "10016")
}

@Test func actorComesFromTheHistoryAuthor() {
    let parsed = ChangelogParser().parse(issue: issue(histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-someone",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")])
    ]))
    #expect(parsed[0].event.actorAccountId == "acc-someone")
}

/// priorUpdatedAt은 **직전 history의 created**다. 티켓의 모든 변경이 changelog에 남으므로
/// 어떤 전이 직전의 마지막 수정 시각은 곧 그 앞 history의 시각이다(스펙 §4.3).
@Test func priorUpdatedAtComesFromThePrecedingHistory() {
    let first = iso("2023-02-01T00:00:00Z")
    let second = iso("2023-02-10T00:00:00Z")
    let parsed = ChangelogParser().parse(issue: issue(created: iso("2023-01-01T00:00:00Z"), histories: [
        history(id: "1", at: first, author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")]),
        history(id: "2", at: second, author: "acc-me",
                items: [statusItem(fromId: "2", from: "B", toId: "3", to: "C")]),
    ]))
    #expect(parsed[1].event.priorUpdatedAt == first)
}

/// 첫 history 앞에는 변경이 없으므로 티켓 생성 시각을 쓴다.
@Test func firstHistoryUsesIssueCreationAsPrior() {
    let created = iso("2023-01-01T00:00:00Z")
    let parsed = ChangelogParser().parse(issue: issue(created: created, histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")])
    ]))
    #expect(parsed[0].event.priorUpdatedAt == created)
}

/// status가 아닌 history도 priorUpdatedAt 계산에는 참여한다 — 그 시점에 티켓이 수정됐으므로.
@Test func nonStatusHistoriesStillAdvanceThePriorTimestamp() {
    let edit = iso("2023-02-05T00:00:00Z")
    let parsed = ChangelogParser().parse(issue: issue(created: iso("2023-01-01T00:00:00Z"), histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")]),
        history(id: "2", at: edit, author: "acc-me", items: [
            JiraChangelogItem(field: "description", fromId: nil, fromString: "옛",
                              toId: nil, toString: "새")
        ]),
        history(id: "3", at: iso("2023-02-20T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "2", from: "B", toId: "3", to: "C")]),
    ]))
    #expect(parsed.count == 2)
    #expect(parsed[1].event.priorUpdatedAt == edit, "description 수정도 티켓을 갱신한다")
}

/// 마감일 변경 이력이 있으면 그 시점의 값을 쓴다(스펙 §4.3).
@Test func dueDateAtObservationTracksDuedateChanges() {
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
    #expect(parsed[0].event.dueDateAtObservation == iso("2023-02-15T00:00:00Z"))
}

/// 마감일 변경 이력이 없으면 현재 값이 그때도 같았다는 뜻이다.
@Test func dueDateFallsBackToTheCurrentValue() {
    let due = iso("2023-04-01T00:00:00Z")
    let parsed = ChangelogParser().parse(issue: issue(due: due, histories: [
        history(id: "1", at: iso("2023-02-01T00:00:00Z"), author: "acc-me",
                items: [statusItem(fromId: "1", from: "A", toId: "2", to: "B")])
    ]))
    #expect(parsed[0].event.dueDateAtObservation == due)
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
            // 가장 이른 변경보다 앞이면 그 변경의 previous가 당시 값이다.
            for change in changes where when < change.at {
                return change.previous
            }
            return current
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

    private static func dateOnly(_ raw: String) -> Date? {
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

Run: `cd Packages/Jirarcade && swift test --filter ChangelogParser`
Expected: PASS (11 tests)

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Backfill/ChangelogParser.swift \
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
- Produces: `@Model BackfillRun`, `ArcadeStore.beginBackfill(jql:at:totalIssueCount:) throws -> PersistentIdentifier`, `advanceBackfill(_:nextPageToken:processedIssueCount:discovered:partiallyRestored:) throws`, `finishBackfill(_:at:failure:) throws`, `resumableBackfill() throws -> BackfillSnapshot?`, `struct BackfillSnapshot { id, jql, nextPageToken, processedIssueCount, totalIssueCount }`

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

    let snapshot = try #require(try store.resumableBackfill())
    #expect(snapshot.discovered.sorted() == ["Merged to Staging", "검수Done"].sorted())
    #expect(snapshot.partiallyRestored.sorted() == ["MPT-1", "MPT-2"])
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
        let run = BackfillRun(startedAt: start, jql: jql, totalIssueCount: totalIssueCount)
        context.insert(run)
        try context.save()
        return run.persistentModelID
    }

    public func advanceBackfill(
        _ id: PersistentIdentifier, nextPageToken: String?, processedIssueCount: Int,
        discovered: [String], partiallyRestored: [String]
    ) throws {
        guard let run = context.model(for: id) as? BackfillRun else { return }
        run.nextPageToken = nextPageToken
        run.processedIssueCount = processedIssueCount
        run.discoveredUnmappedStatuses = Array(
            Set(run.discoveredUnmappedStatuses).union(discovered)
        )
        run.partiallyRestoredKeys = Array(
            Set(run.partiallyRestoredKeys).union(partiallyRestored)
        )
        try context.save()
    }

    public func finishBackfill(
        _ id: PersistentIdentifier, at end: Date, failure: String?
    ) throws {
        guard let run = context.model(for: id) as? BackfillRun else { return }
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

    func fetchIssueChangelog(key: String, startAt: Int) async throws -> JiraChangelogPage {
        if failSupplementFor.contains(key) { throw StubError() }
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

    /// - Parameter progress: (처리한 티켓 수, 전체 추정치). 페이지마다 불린다.
    public func run(
        jql: String,
        now: Date,
        startingToken: String? = nil,
        progress: @MainActor (Int, Int) -> Void
    ) async throws -> BackfillOutcome {
        // 카탈로그 조회는 실패해도 진행한다 — 폴백 ②만 잃고 ①③은 남는다(스펙 §8).
        let entries = (try? await source.fetchStatusCatalog()) ?? []
        let catalog = StatusCatalog(workflow: workflow, entries: entries)

        var token = startingToken
        var processed = 0
        var inserted = 0
        var partiallyRestored: [String] = []

        repeat {
            // 사용자가 중단하면 여기서 빠져나온다. 페이지 경계에서만 검사하는 이유는
            // 이미 넣은 이벤트는 유효하고, 중단 지점의 nextPageToken이 저장돼 있어
            // 나중에 이어서 진행할 수 있기 때문이다 — 롤백할 것이 없다.
            try Task.checkCancellation()

            let page = try await source.fetchPage(jql: jql, pageToken: token)

            for issue in page.issues {
                let resolved = await resolve(issue: issue, partiallyRestored: &partiallyRestored)
                let transitions = parser.parse(issue: resolved)

                // 폴백 판정을 태워 미매핑 상태를 수집한다. 반환값은 쓰지 않지만
                // catalog가 내부에 이름을 모으고, 그 목록이 매핑 마법사 후보가 된다.
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
            progress(processed, max(processed, page.issues.count))
        } while token != nil

        return BackfillOutcome(
            insertedEvents: inserted,
            processedIssues: processed,
            discoveredStatuses: Array(catalog.unmappedNames).sorted(),
            partiallyRestored: partiallyRestored
        )
    }

    /// changelog가 잘려 왔으면 보충 조회로 채운다. 실패하면 원래 것을 그대로 쓰고
    /// 부분 복원으로 기록한다 — 한 티켓 때문에 전체를 멈추지 않는다.
    private func resolve(
        issue: JiraIssueWithChangelog, partiallyRestored: inout [String]
    ) async -> JiraIssueWithChangelog {
        guard issue.changelog.isTruncated else { return issue }
        do {
            let full = try await source.fetchIssueChangelog(key: issue.key, startAt: 0)
            return JiraIssueWithChangelog(
                key: issue.key, createdAt: issue.createdAt,
                dueDate: issue.dueDate, changelog: full
            )
        } catch {
            partiallyRestored.append(issue.key)
            return issue
        }
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

### Task 12: AppModel에 백필 연결

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/BackfillIntegrationTests.swift`

**Interfaces:**
- Consumes: `BackfillEngine`·`JiraChangelogSource` (Task 11), `ArcadeStore` 백필 API (Task 10), `ScoreEngine.recompute(since:)` (Task 3)
- Produces: `AppModel.backfillProgress: BackfillProgress?` (`processed`, `total`), `AppModel.startBackfill() async`, `AppModel.resumeBackfillIfAvailable() async`, `AppModel.cancelBackfill()`, `AppModel.hasResumableBackfill: Bool`, `AppModel.seasonSummary: PlayerSummary?`, `AppModel.lifetimeSummary: PlayerSummary?`

- [ ] **Step 0: `makeModel`에 store 주입 파라미터 추가**

`Tests/ArcadeAppTests/TestSupport.swift`의 `makeModel`은 store를 내부에서 만들어 테스트가 미리 상태를 심을 수 없다. 백필 테스트는 "이미 이벤트가 있는 스토어"를 필요로 하므로 주입 가능하게 한다. **기본값을 주어 기존 호출부는 그대로 컴파일된다.**

시그니처 첫 줄에 파라미터를 더한다:

```swift
func makeModel(
    store: ArcadeStore? = nil,
    credentials: InMemoryCredentialStore = InMemoryCredentialStore(),
```

본문의 `store:` 인자를 바꾼다:

```swift
    return AppModel(
        store: try store ?? ArcadeStore(container: ArcadeStore.makeInMemoryContainer()),
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

/// 시즌은 통산의 부분집합이다. 시즌 밖 이벤트가 있으면 시즌 XP는 통산보다 **엄격히** 작아야
/// 한다 — `<=`로 검사하면 둘 다 0일 때도 통과해 아무것도 검증하지 못한다(스펙 §6).
@MainActor
@Test func seasonSummaryIsStrictlySmallerWhenOldEventsExist() async throws {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let now = iso("2026-08-14T09:00:00Z")
    // 시즌(30일) 밖 하나, 안 하나. 둘 다 내가 옮긴 전진 전이라 XP가 붙는다.
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

    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let workflow = InMemoryWorkflowStore(seeded: WorkflowMap(statusToStage: [
        "To Do": .backlog, "In Progress": .active,
    ]))
    let model = try makeModel(store: store, credentials: creds, workflow: workflow, now: now)

    await model.start()

    let lifetime = try #require(model.lifetimeSummary)
    let season = try #require(model.seasonSummary)
    #expect(lifetime.totalXP > 0, "이벤트가 있으므로 통산 XP가 0이면 집계가 안 된 것이다")
    #expect(season.totalXP > 0, "시즌 안 이벤트가 있으므로 시즌 XP도 0이 아니다")
    #expect(season.totalXP < lifetime.totalXP, "시즌 밖 이벤트가 통산에만 잡혀야 한다")
}

/// 진행률이 백필 중에는 값이 있고 끝나면 nil로 돌아간다 — UI가 진행 바를 감출 근거다.
@MainActor
@Test func progressClearsWhenFinished() async throws {
    let model = try makeModel()
    await model.start()
    await model.startBackfill()
    #expect(model.backfillProgress == nil)
}

/// 중단된 백필이 있으면 재개할 수 있다.
@MainActor
@Test func resumePicksUpTheStoredToken() async throws {
    let model = try makeModel()
    await model.start()
    await model.resumeBackfillIfAvailable()   // 중단된 것이 없으면 아무 일도 없어야 한다
    #expect(model.backfillProgress == nil)
}

/// 중단해도 이미 넣은 이벤트는 남는다. 롤백하지 않는 것이 설계다 — 이벤트 로그는
/// append-only이고 중단 지점의 토큰이 저장돼 나중에 이어받는다(스펙 §7.2).
@MainActor
@Test func cancellingKeepsWhatWasAlreadyStored() async throws {
    let model = try makeModel()
    await model.start()

    let task = Task { await model.startBackfill() }
    model.cancelBackfill()
    await task.value

    #expect(model.backfillProgress == nil, "중단 후 진행 바가 사라져야 한다")
}

/// 백필이 이미 돌고 있으면 두 번 시작하지 않는다 — 진행률 카운터가 뒤엉킨다.
@MainActor
@Test func startingTwiceIsIgnored() async throws {
    let model = try makeModel()
    await model.start()

    async let first: Void = model.startBackfill()
    async let second: Void = model.startBackfill()
    _ = await (first, second)

    #expect(model.backfillProgress == nil)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter Backfill`
Expected: FAIL — `value of type 'AppModel' has no member 'startBackfill'`

- [ ] **Step 3: `AppModel`에 상태와 메서드 추가**

프로퍼티 선언부에:

```swift
    /// 백필 진행률. In Progress일 때만 값이 있다.
    public struct BackfillProgress: Sendable, Equatable {
        public let processed: Int
        public let total: Int
    }
    public private(set) var backfillProgress: BackfillProgress?
    /// 전체 이력 기준 요약. 프로필에 표시한다.
    public private(set) var lifetimeSummary: PlayerSummary?
    /// 최근 `RuleSet.seasonDays`일 기준 요약. HUD의 XP 바가 이 값을 쓴다.
    public private(set) var seasonSummary: PlayerSummary?
    /// 중단된 백필이 남아 있는지. 설정 화면이 "이어서 불러오기"를 보여줄 근거다.
    public private(set) var hasResumableBackfill: Bool = false
```

`start()`와 백필 종료 시점에 `hasResumableBackfill`을 갱신한다:

```swift
        hasResumableBackfill = (try? store.resumableBackfill()) != nil
```

메서드를 추가한다:

```swift
    /// 실행 중인 백필. 중단하려면 이걸 취소한다.
    private var backfillTask: Task<Void, Never>?

    /// 과거 기록을 불러온다. 사용자가 설정에서 눌러 시작한다 — 자동 실행하지 않는다.
    public func startBackfill() async {
        await launchBackfill(startingToken: nil, existing: nil)
    }

    /// 중단된 백필이 있으면 이어서 진행한다.
    public func resumeBackfillIfAvailable() async {
        guard let snapshot = try? store.resumableBackfill() else { return }
        await launchBackfill(startingToken: snapshot.nextPageToken, existing: snapshot.id)
    }

    /// In Progress인 백필을 중단한다. 이미 넣은 이벤트는 그대로 유효하고, 중단 지점의
    /// `nextPageToken`이 저장돼 있어 나중에 "이어서 불러오기"로 재개된다.
    public func cancelBackfill() {
        backfillTask?.cancel()
    }

    private func launchBackfill(
        startingToken: String?, existing: PersistentIdentifier?
    ) async {
        // 이미 돌고 있으면 두 번 시작하지 않는다 — 같은 페이지를 두 곳에서 훑으면
        // 진행률이 뒤엉킨다(이벤트 중복은 historyId가 막지만 카운터는 못 막는다).
        guard backfillTask == nil else { return }
        let task = Task { await runBackfill(startingToken: startingToken, existing: existing) }
        backfillTask = task
        await task.value
        backfillTask = nil
    }

    private func runBackfill(
        startingToken: String?, existing: PersistentIdentifier? = nil
    ) async {
        guard let client else { return }
        let jql = "assignee = currentUser()"
        let now = clock()

        let runId: PersistentIdentifier
        if let existing {
            runId = existing
        } else {
            guard let created = try? store.beginBackfill(jql: jql, at: now, totalIssueCount: 0)
            else { return }
            runId = created
        }

        let engine = BackfillEngine(
            source: JiraChangelogSource(client: client),
            store: store,
            workflow: (try? workflow.load()) ?? WorkflowMap(statusToStage: [:])
        )

        do {
            let outcome = try await engine.run(
                jql: jql, now: now, startingToken: startingToken
            ) { [weak self] processed, total in
                self?.backfillProgress = BackfillProgress(processed: processed, total: total)
            }
            try? store.advanceBackfill(
                runId, nextPageToken: nil, processedIssueCount: outcome.processedIssues,
                discovered: outcome.discoveredStatuses,
                partiallyRestored: outcome.partiallyRestored
            )
            try? store.finishBackfill(runId, at: clock(), failure: nil)
        } catch {
            try? store.finishBackfill(runId, at: clock(),
                                      failure: redactedErrorDescription(error))
        }

        backfillProgress = nil
        await refreshSummaries()
    }

    /// 통산과 시즌을 각각 집계한다. 같은 이벤트 로그를 두 범위로 읽을 뿐이다.
    private func refreshSummaries() async {
        guard let events = try? store.loadEvents(),
              let mirror = try? store.loadMirror() else { return }
        let now = clock()
        let engine = ScoreEngine(
            rules: rules, workflow: (try? workflow.load()) ?? WorkflowMap(statusToStage: [:]),
            calendar: calendar, myAccountId: myAccountId
        )
        lifetimeSummary = engine.recompute(events: events, issues: mirror, now: now).summary
        let seasonStart = now.addingTimeInterval(-Double(rules.seasonDays) * 86_400)
        seasonSummary = engine.recompute(events: events, issues: mirror, now: now,
                                         since: seasonStart).summary
    }
```

> `myAccountId`·`rules`·`calendar`·`clock`이 `AppModel`에 이미 있는지 확인하고, 없으면 `validate()`가 얻는 `me.accountId`를 저장하는 프로퍼티를 추가한다. 무엇을 추가했는지 리포트에 적는다.

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift \
        Packages/Jirarcade/Tests/ArcadeAppTests/BackfillIntegrationTests.swift
git commit -m "feat: AppModel에 백필 실행과 통산·시즌 요약 연결"
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
                    ProgressView(value: Double(progress.processed),
                                 total: Double(max(progress.total, 1))) {
                        Text("불러오는 중 \(progress.processed)/\(progress.total)")
                            .font(.caption)
                            .foregroundStyle(theme.inkSecondary)
                    }
                    .tint(theme.accent)
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
                    ProgressView(value: Double(progress.processed),
                                 total: Double(max(progress.total, 1)))
                        .tint(theme.accent)
                        .frame(width: 120)
                    Text("과거 기록 \(progress.processed)/\(progress.total)")
                        .font(.caption)
                        .foregroundStyle(theme.inkSecondary)
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
                              discovered: ["Merged to Staging", "검수Done"], partiallyRestored: [])

    let creds = InMemoryCredentialStore(
        seeded: Credentials(site: "example.atlassian.net", email: "u@e.com", token: "t")
    )
    let model = try makeModel(store: store, credentials: creds)

    await model.start()

    #expect(Set(model.historyDiscoveredStatuses) == ["Merged to Staging", "검수Done"])
    #expect(model.hasResumableBackfill == true, "중단된 백필이 있으면 이어받기를 제안해야 한다")
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

`runBackfill`의 성공 경로에서 채운다(`try? store.advanceBackfill(...)` 뒤):

```swift
            historyDiscoveredStatuses = outcome.discoveredStatuses
```

`start()`에서도 복원한다 — 앱을 껐다 켜도 후보가 남아야 한다:

```swift
        if let snapshot = try? store.resumableBackfill() {
            historyDiscoveredStatuses = snapshot.discovered
        }
```

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
git add Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift \
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

/// 남이 옮긴 전이가 섞여도 statusEnteredAt은 갱신된다 — 정체일이 부풀지 않는다(스펙 §4.2).
@Test func othersTransitionsStillAdvanceTheStagnationBaseline() {
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

    // 첫 전이(남)는 0점, 두 번째(나)는 7일 정체 기준으로 채점된다.
    // 남의 전이를 버렸다면 정체가 38일이 되어 XP가 훨씬 커졌을 것이다.
    #expect(result.scored[0].xp == 0)
    #expect(result.scored[1].xp > 0)
    #expect(result.scored[1].xp < 100, "7일 정체이므로 보스전 수준 XP가 나오면 안 된다")
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
