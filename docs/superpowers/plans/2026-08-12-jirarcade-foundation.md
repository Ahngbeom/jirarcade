# Jirarcade 기반 계층 (JiraKit + ArcadeCore) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Jira Cloud에서 티켓을 읽어와 로컬 미러와 이벤트 로그를 만들고, 그 위에서 XP·레벨·연속 기록·위생 점수를 계산하는 UI 없는 라이브러리 계층을 완성한다.

**Architecture:** `JiraKit`은 Jira Cloud REST v3 통신과 인증만 담당하며 게임 개념을 전혀 모른다. `ArcadeCore`는 `JiraKit`의 DTO를 순수 값 타입으로 변환해 미러에 저장하고, 스냅샷 비교(diff)로 이벤트를 생성한 뒤 규칙 엔진으로 점수를 집계한다. 규칙 엔진은 SwiftData나 네트워크에 의존하지 않는 순수 함수 집합이며, 모든 시간 의존 함수는 `now: Date`를 파라미터로 받는다.

**Tech Stack:** Swift 6.2 / Swift Package Manager / Swift Testing (`import Testing`) / SwiftData / Foundation `URLSession`

## Global Constraints

- 스펙 원본: `docs/superpowers/specs/2026-08-12-jirarcade-design.md`. 충돌 시 스펙이 우선한다.
- 모듈 의존 방향은 단방향이다: `ArcadeCore → JiraKit`. 역방향 import는 금지한다.
- `JiraKit`은 XP·레벨·정체 등 게임 개념 타입을 정의하거나 참조하지 않는다.
- 시간에 의존하는 모든 공개 함수는 `now: Date`를 파라미터로 받는다. 함수 본문에서 `Date()`를 호출하지 않는다.
- `IssueEvent`(이벤트 로그)는 append-only다. 갱신·삭제하는 코드를 작성하지 않는다.
- 규칙 상수는 코드에 하드코딩하지 않고 전부 `RuleSet`에서 읽는다.
- 상태명은 조직 커스텀 값(`"In Progress"`, `"In Review"`, `"Verifying"`)을 그대로 보존하고, 게임 단계 변환은 `WorkflowMap`을 통해서만 한다.
- 토큰·이메일을 로그나 에러 메시지에 포함하지 않는다.
- 테스트 프레임워크는 Swift Testing(`@Test` / `#expect`)을 쓴다. XCTest를 새로 작성하지 않는다.
- 각 태스크는 테스트 통과 후 커밋으로 끝난다.

## File Structure

```
Packages/Jirarcade/
├── Package.swift
├── Sources/
│   ├── JiraKit/
│   │   ├── HTTPClient.swift            HTTP 전송 추상화 + URLSession 구현
│   │   ├── AuthProvider.swift          인증 + 베이스 URL 추상화
│   │   ├── APITokenAuth.swift          Basic auth 구현체
│   │   ├── JiraError.swift             HTTP 응답 → 도메인 에러 매핑
│   │   ├── JiraClient.swift            검색·전이·myself 엔드포인트
│   │   └── DTO.swift                   JiraIssue / JiraTransition / JiraUser / Failable
│   └── ArcadeCore/
│       ├── Domain/RuleSet.swift        모든 규칙 상수 (Codable)
│       ├── Domain/WorkflowMap.swift    상태명 → Stage 매핑
│       ├── Domain/ObservedIssue.swift  순수 값 타입 + JiraIssue 변환
│       ├── Domain/DomainEvent.swift    EventKind / DomainEvent / ScoredEvent
│       ├── Rules/StagnationClassifier.swift
│       ├── Rules/HygieneCalculator.swift
│       ├── Rules/StreakCalculator.swift
│       ├── Rules/LevelCurve.swift
│       ├── Rules/XpAwarder.swift
│       ├── Rules/AbuseGuard.swift
│       ├── Rules/ScoreEngine.swift     이벤트 → 점수 집계 (재집계 진입점)
│       ├── Sync/DiffEngine.swift       스냅샷 비교 → 이벤트 생성
│       ├── Sync/SyncEngine.swift       페치 → diff → 저장 조합
│       ├── Store/StoreModels.swift     SwiftData @Model 4종
│       └── Store/ArcadeStore.swift     @Model ↔ 값 타입 변환 + 영속화
└── Tests/
    ├── JiraKitTests/
    │   ├── StubHTTPClient.swift
    │   ├── AuthTests.swift
    │   ├── DecodingTests.swift
    │   └── ErrorMappingTests.swift
    └── ArcadeCoreTests/
        ├── TestSupport.swift           날짜 헬퍼 · 샘플 티켓 빌더
        ├── WorkflowMapTests.swift
        ├── StagnationTests.swift
        ├── HygieneTests.swift
        ├── StreakTests.swift
        ├── LevelCurveTests.swift
        ├── XpAwarderTests.swift
        ├── AbuseGuardTests.swift
        ├── ScoreEngineTests.swift
        ├── DiffEngineTests.swift
        └── StoreTests.swift
```

---

### Task 1: 패키지 스캐폴드와 테스트 러너 확인

**Files:**
- Create: `Packages/Jirarcade/Package.swift`
- Create: `Packages/Jirarcade/Sources/JiraKit/HTTPClient.swift`
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Domain/RuleSet.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/TestSupport.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/RuleSetTests.swift`
- Create: `.gitignore`

**Interfaces:**
- Consumes: 없음 (최초 태스크)
- Produces: `RuleSet` 구조체와 `RuleSet.default`, 테스트 헬퍼 `iso(_:) -> Date`, `days(_:) -> TimeInterval`

- [ ] **Step 1: `.gitignore` 작성**

```gitignore
.DS_Store
.build/
.swiftpm/
DerivedData/
*.xcuserstate
```

- [ ] **Step 2: `Package.swift` 작성**

`platforms`를 `.macOS(.v15)`로 둔다. SwiftData·Observation·Swift Testing이 모두 지원되는 하한이며, 앱 타깃이 macOS 26을 요구하는 것과 모순되지 않는다(하한이 낮을 뿐이다).

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Jirarcade",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "JiraKit", targets: ["JiraKit"]),
        .library(name: "ArcadeCore", targets: ["ArcadeCore"]),
    ],
    targets: [
        .target(name: "JiraKit"),
        .target(name: "ArcadeCore", dependencies: ["JiraKit"]),
        .testTarget(name: "ArcadeCoreTests", dependencies: ["ArcadeCore"]),
    ]
)
```

> `JiraKitTests` 타깃은 여기서 선언하지 않는다. SwiftPM은 소스 파일이 하나도 없는 타깃에 빌드 경고를 내는데, 첫 JiraKit 테스트는 Task 12에서야 생긴다. 그 태스크가 타깃 선언도 함께 추가한다.

- [ ] **Step 3: `JiraKit`에 최소 파일 하나 추가** (타깃이 비어 있으면 빌드가 실패한다)

`Sources/JiraKit/HTTPClient.swift`:

```swift
import Foundation

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
```

- [ ] **Step 4: 테스트 헬퍼 작성**

`Tests/ArcadeCoreTests/TestSupport.swift`:

```swift
import Foundation

/// 테스트에서 고정 시각을 만든다. 실패 시 즉시 크래시시켜 잘못된 리터럴을 빨리 드러낸다.
func iso(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: string) else {
        fatalError("잘못된 ISO8601 리터럴: \(string)")
    }
    return date
}

func days(_ count: Double) -> TimeInterval { count * 86_400 }
func minutes(_ count: Double) -> TimeInterval { count * 60 }
func hours(_ count: Double) -> TimeInterval { count * 3_600 }
```

- [ ] **Step 5: 실패하는 테스트 작성**

`Tests/ArcadeCoreTests/RuleSetTests.swift`:

```swift
import Testing
import Foundation
@testable import ArcadeCore

@Test func defaultRuleSetMatchesSpec() {
    let rules = RuleSet.default
    #expect(rules.staleDays == 7)
    #expect(rules.bossDays == 21)
    #expect(rules.raidDays == 45)
    #expect(rules.wipLimit == 5)
    #expect(rules.dailyXPCap == 1_200)
    #expect(rules.levelExponent == 1.8)
}

@Test func ruleSetSurvivesJSONRoundTrip() throws {
    let data = try JSONEncoder().encode(RuleSet.default)
    let decoded = try JSONDecoder().decode(RuleSet.self, from: data)
    #expect(decoded == RuleSet.default)
}
```

- [ ] **Step 6: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test`
Expected: FAIL — `cannot find 'RuleSet' in scope`

- [ ] **Step 7: `RuleSet` 구현**

`Sources/ArcadeCore/Domain/RuleSet.swift`:

```swift
import Foundation

/// 게임 규칙 상수 전체. 코드에 숫자를 하드코딩하지 않고 이 구조체에서만 읽는다.
/// Codable이므로 설정 화면에서 JSON으로 편집하고 재집계할 수 있다.
public struct RuleSet: Codable, Sendable, Equatable {
    // 정체 등급 경계 (일)
    public var staleDays: Int
    public var bossDays: Int
    public var raidDays: Int

    // 깨우기 XP
    public var wakeBaseXP: Int
    public var wakeDivisorDays: Double
    public var wakeMaxMultiplier: Double
    public var forwardMultiplier: Double

    // 위생 감점
    public var hygieneMaxScore: Int
    public var wipLimit: Int
    public var wipPenalty: Int
    public var zombieDays: Int
    public var zombiePenalty: Int
    public var ghostPenalty: Int
    public var hygieneBonusThreshold: Int
    public var hygieneBonusXP: Int

    // 마감 방어
    public var maxHP: Int

    // 연속 기록
    public var streakStepBonus: Double
    public var streakCapDays: Int
    public var countsWeekends: Bool

    // 마감 보너스
    public var dueBonusPerDay: Int
    public var dueBonusCap: Int

    // 어뷰징 방지
    public var dailyXPCap: Int
    public var duplicateWindowHours: Double
    public var revertWindowMinutes: Double

    // 레벨 곡선
    public var levelBase: Double
    public var levelExponent: Double

    public static let `default` = RuleSet(
        staleDays: 7, bossDays: 21, raidDays: 45,
        wakeBaseXP: 40, wakeDivisorDays: 14, wakeMaxMultiplier: 4.0, forwardMultiplier: 1.5,
        hygieneMaxScore: 100,
        wipLimit: 5, wipPenalty: 8, zombieDays: 7, zombiePenalty: 6, ghostPenalty: 10,
        hygieneBonusThreshold: 80, hygieneBonusXP: 50,
        maxHP: 3,
        streakStepBonus: 0.05, streakCapDays: 14, countsWeekends: false,
        dueBonusPerDay: 10, dueBonusCap: 80,
        dailyXPCap: 1_200, duplicateWindowHours: 24, revertWindowMinutes: 10,
        levelBase: 100, levelExponent: 1.8
    )
}
```

- [ ] **Step 8: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS (2 tests)

- [ ] **Step 9: 커밋**

```bash
git add .gitignore Packages/
git commit -m "feat: SPM 패키지 스캐폴드와 RuleSet 추가"
```

---

### Task 2: WorkflowMap — 커스텀 상태명을 게임 단계로

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Domain/WorkflowMap.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/WorkflowMapTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces: `enum Stage: String` (`backlog`/`active`/`review`/`verify`/`done`)와 `Stage.order: Int`, `WorkflowMap.stage(for: String) -> Stage?`, `WorkflowMap.unmappedStatuses(in: [String]) -> [String]`, `demoWorkflow`

- [ ] **Step 1: 실패하는 테스트 작성**

미매핑 상태를 `.backlog`로 조용히 폴백시키지 않는 것이 핵심이다. 관리자가 새 상태를 추가했을 때 점수가 틀린 채로 계산되는 대신, 호출부가 "매핑 안 됨"을 알 수 있어야 한다.

```swift
import Testing
@testable import ArcadeCore

@Test func mptMappingCoversRealStatuses() {
    let map = demoWorkflow
    #expect(map.stage(for: "To Do") == .backlog)
    #expect(map.stage(for: "In Progress") == .active)
    #expect(map.stage(for: "In Review") == .review)
    #expect(map.stage(for: "Verifying") == .verify)
    #expect(map.stage(for: "Done") == .done)
}

@Test func unknownStatusReturnsNilRatherThanFallback() {
    #expect(demoWorkflow.stage(for: "검토 대기") == nil)
}

@Test func unmappedStatusesAreReported() {
    let found = demoWorkflow.unmappedStatuses(in: ["In Progress", "검토 대기", "보류", "In Progress"])
    #expect(found == ["검토 대기", "보류"])
}

@Test func stageOrderIsMonotonic() {
    let ordered: [Stage] = [.backlog, .active, .review, .verify, .done]
    let orders = ordered.map(\.order)
    #expect(orders == [0, 1, 2, 3, 4])
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter WorkflowMap`
Expected: FAIL — `cannot find 'WorkflowMap' in scope`

- [ ] **Step 3: 구현**

```swift
import Foundation

/// 게임이 이해하는 진행 단계. 조직의 상태명과 1:1이 아니며 WorkflowMap을 통해서만 변환된다.
public enum Stage: String, Codable, Sendable, CaseIterable {
    case backlog, active, review, verify, done

    /// 전진/후퇴 판정에 쓰는 순서값.
    public var order: Int {
        switch self {
        case .backlog: 0
        case .active:  1
        case .review:  2
        case .verify:  3
        case .done:    4
        }
    }
}

public struct WorkflowMap: Codable, Sendable, Equatable {
    public var statusToStage: [String: Stage]

    public init(statusToStage: [String: Stage]) {
        self.statusToStage = statusToStage
    }

    /// 매핑되지 않은 상태는 nil을 돌려준다. 임의의 단계로 폴백하면 점수가 조용히 틀린다.
    public func stage(for statusName: String) -> Stage? {
        statusToStage[statusName]
    }

    /// 입력에 등장한 상태 중 매핑되지 않은 것을 최초 등장 순서대로, 중복 없이 돌려준다.
    public func unmappedStatuses(in statusNames: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in statusNames where statusToStage[name] == nil {
            if seen.insert(name).inserted { result.append(name) }
        }
        return result
    }

    /// 워크플로 매핑은 인스턴스마다 다르므로 앱에 내장하지 않는다.
    /// 사용자가 설정에서 지정하고, 토큰과 같은 등급으로 로컬에 저장한다.
    public static let mpt = WorkflowMap(statusToStage: [
        "To Do": .backlog,
        "In Progress": .active,
        "In Review": .review,
        "Verifying": .verify,
        "Done": .done,
    ])
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter WorkflowMap`
Expected: PASS (4 tests)

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Domain/WorkflowMap.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/WorkflowMapTests.swift
git commit -m "feat: WorkflowMap으로 커스텀 상태명을 게임 단계에 매핑"
```

---

### Task 3: ObservedIssue와 DomainEvent — 순수 값 타입

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Domain/ObservedIssue.swift`
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Domain/DomainEvent.swift`
- Modify: `Packages/Jirarcade/Tests/ArcadeCoreTests/TestSupport.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/DomainTypeTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces: `ObservedIssue` (필드: `key`, `summary`, `statusName`, `issueType`, `priority`, `assigneeAccountId`, `assigneeName`, `dueDate`, `jiraUpdatedAt`), `enum EventKind`, `DomainEvent`, `ScoredEvent`, 테스트 빌더 `issue(...) -> ObservedIssue`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/ArcadeCoreTests/DomainTypeTests.swift`:

```swift
import Testing
import Foundation
@testable import ArcadeCore

@Test func issueIdentityIsTheKey() {
    let a = issue(key: "DEMO-1", status: "In Progress")
    #expect(a.id == "DEMO-1")
}

@Test func eventKindRoundTripsThroughRawValue() {
    for kind in EventKind.allCases {
        #expect(EventKind(rawValue: kind.rawValue) == kind)
    }
}

@Test func scoredEventCarriesItsEvent() {
    let event = DomainEvent(issueKey: "DEMO-1", kind: .touched,
                            fromStatus: nil, toStatus: nil,
                            observedAt: iso("2026-08-12T09:00:00Z"),
                            actorAccountId: "acc-1")
    let scored = ScoredEvent(event: event, xp: 40)
    #expect(scored.event.issueKey == "DEMO-1")
    #expect(scored.xp == 40)
}
```

- [ ] **Step 2: 테스트 빌더를 `TestSupport.swift`에 추가**

기본값을 채워두면 이후 모든 테스트가 관심 있는 필드만 지정할 수 있다.

```swift
@testable import ArcadeCore

func issue(
    key: String,
    summary: String = "샘플 티켓",
    status: String,
    type: String = "개선",
    priority: String? = "Medium",
    assignee: String? = "acc-me",
    assigneeName: String? = "bahn",
    due: Date? = nil,
    updated: Date = iso("2026-08-12T00:00:00Z")
) -> ObservedIssue {
    ObservedIssue(
        key: key, summary: summary, statusName: status, issueType: type,
        priority: priority, assigneeAccountId: assignee, assigneeName: assigneeName,
        dueDate: due, jiraUpdatedAt: updated
    )
}
```

- [ ] **Step 3: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter DomainType`
Expected: FAIL — `cannot find 'ObservedIssue' in scope`

- [ ] **Step 4: `ObservedIssue` 구현**

```swift
import Foundation

/// 규칙 엔진이 다루는 티켓의 값 표현. SwiftData나 네트워크 타입에 의존하지 않는다.
public struct ObservedIssue: Sendable, Equatable, Identifiable {
    public var id: String { key }

    public let key: String
    public let summary: String
    public let statusName: String
    public let issueType: String
    public let priority: String?
    public let assigneeAccountId: String?
    public let assigneeName: String?
    public let dueDate: Date?
    public let jiraUpdatedAt: Date

    public init(
        key: String, summary: String, statusName: String, issueType: String,
        priority: String?, assigneeAccountId: String?, assigneeName: String?,
        dueDate: Date?, jiraUpdatedAt: Date
    ) {
        self.key = key
        self.summary = summary
        self.statusName = statusName
        self.issueType = issueType
        self.priority = priority
        self.assigneeAccountId = assigneeAccountId
        self.assigneeName = assigneeName
        self.dueDate = dueDate
        self.jiraUpdatedAt = jiraUpdatedAt
    }
}
```

- [ ] **Step 5: `DomainEvent` 구현**

```swift
import Foundation

public enum EventKind: String, Codable, Sendable, CaseIterable {
    case appeared        // 조회 결과에 처음 등장
    case statusChanged   // 상태 전이 관측
    case touched         // 상태는 그대로인데 jiraUpdatedAt이 움직임
    case dueDateChanged
    case vanished        // 조회 결과에서 사라짐 (완료 또는 재할당)
}

/// 우리가 관측한 변화 한 건. 생성 후 절대 수정하지 않는다(append-only).
public struct DomainEvent: Sendable, Equatable {
    public let issueKey: String
    public let kind: EventKind
    public let fromStatus: String?
    public let toStatus: String?
    public let observedAt: Date
    public let actorAccountId: String?

    public init(
        issueKey: String, kind: EventKind, fromStatus: String?, toStatus: String?,
        observedAt: Date, actorAccountId: String?
    ) {
        self.issueKey = issueKey
        self.kind = kind
        self.fromStatus = fromStatus
        self.toStatus = toStatus
        self.observedAt = observedAt
        self.actorAccountId = actorAccountId
    }
}

/// 이벤트에 XP를 매긴 결과. XP는 파생값이므로 이벤트와 분리한다.
public struct ScoredEvent: Sendable, Equatable {
    public let event: DomainEvent
    public var xp: Int

    public init(event: DomainEvent, xp: Int) {
        self.event = event
        self.xp = xp
    }
}
```

- [ ] **Step 6: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter DomainType`
Expected: PASS (3 tests)

- [ ] **Step 7: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Domain/ \
        Packages/Jirarcade/Tests/ArcadeCoreTests/
git commit -m "feat: ObservedIssue와 DomainEvent 값 타입 추가"
```

---

### Task 4: StagnationClassifier — 정체 등급 판정

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Rules/StagnationClassifier.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/StagnationTests.swift`

**Interfaces:**
- Consumes: `RuleSet` (Task 1)
- Produces: `enum StagnationTier: Comparable` (`fresh`/`stale`/`boss`/`raid`), `StagnationClassifier(rules:)`, `daysStagnant(statusEnteredAt:jiraUpdatedAt:now:) -> Int`, `classify(statusEnteredAt:jiraUpdatedAt:now:) -> StagnationTier`, `isApproximate(statusEnteredAt:) -> Bool`

- [ ] **Step 1: 실패하는 테스트 작성**

`statusEnteredAt`이 있으면 그것을 쓰고 없으면 `jiraUpdatedAt`으로 근사한다는 2단 규칙이 이 태스크의 핵심이다.

```swift
import Testing
import Foundation
@testable import ArcadeCore

private let now = iso("2026-08-12T00:00:00Z")
private let classifier = StagnationClassifier(rules: .default)

@Test func prefersStatusEnteredAtOverJiraUpdatedAt() {
    let stagnant = classifier.daysStagnant(
        statusEnteredAt: now.addingTimeInterval(-days(30)),
        jiraUpdatedAt: now.addingTimeInterval(-days(1)),
        now: now
    )
    #expect(stagnant == 30)
}

@Test func fallsBackToJiraUpdatedAtWhenNoHistory() {
    let stagnant = classifier.daysStagnant(
        statusEnteredAt: nil,
        jiraUpdatedAt: now.addingTimeInterval(-days(6)),
        now: now
    )
    #expect(stagnant == 6)
}

@Test func approximateFlagTracksMissingHistory() {
    #expect(classifier.isApproximate(statusEnteredAt: nil) == true)
    #expect(classifier.isApproximate(statusEnteredAt: now) == false)
}

@Test(arguments: [
    (0, StagnationTier.fresh),
    (6, StagnationTier.fresh),
    (7, StagnationTier.stale),
    (20, StagnationTier.stale),
    (21, StagnationTier.boss),
    (44, StagnationTier.boss),
    (45, StagnationTier.raid),
    (120, StagnationTier.raid),
])
func classifiesAtBoundaries(elapsed: Int, expected: StagnationTier) {
    let tier = classifier.classify(
        statusEnteredAt: now.addingTimeInterval(-days(Double(elapsed))),
        jiraUpdatedAt: now,
        now: now
    )
    #expect(tier == expected)
}

@Test func futureTimestampsClampToZero() {
    let stagnant = classifier.daysStagnant(
        statusEnteredAt: now.addingTimeInterval(days(3)),
        jiraUpdatedAt: now,
        now: now
    )
    #expect(stagnant == 0)
}

@Test func tiersAreOrdered() {
    #expect(StagnationTier.fresh < StagnationTier.stale)
    #expect(StagnationTier.stale < StagnationTier.boss)
    #expect(StagnationTier.boss < StagnationTier.raid)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter Stagnation`
Expected: FAIL — `cannot find 'StagnationClassifier' in scope`

- [ ] **Step 3: 구현**

```swift
import Foundation

public enum StagnationTier: String, Sendable, Comparable, CaseIterable {
    case fresh, stale, boss, raid

    private var rank: Int {
        switch self {
        case .fresh: 0
        case .stale: 1
        case .boss:  2
        case .raid:  3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public struct StagnationClassifier: Sendable {
    private let rules: RuleSet

    public init(rules: RuleSet) {
        self.rules = rules
    }

    /// 관측 이력(statusEnteredAt)이 없으면 근사 기준을 쓴다는 사실을 호출부가 UI에 표시할 수 있게 노출한다.
    public func isApproximate(statusEnteredAt: Date?) -> Bool {
        statusEnteredAt == nil
    }

    public func daysStagnant(statusEnteredAt: Date?, jiraUpdatedAt: Date, now: Date) -> Int {
        let reference = statusEnteredAt ?? jiraUpdatedAt
        let elapsed = now.timeIntervalSince(reference)
        guard elapsed > 0 else { return 0 }
        return Int(elapsed / 86_400)
    }

    public func classify(statusEnteredAt: Date?, jiraUpdatedAt: Date, now: Date) -> StagnationTier {
        let elapsed = daysStagnant(statusEnteredAt: statusEnteredAt, jiraUpdatedAt: jiraUpdatedAt, now: now)
        if elapsed >= rules.raidDays { return .raid }
        if elapsed >= rules.bossDays { return .boss }
        if elapsed >= rules.staleDays { return .stale }
        return .fresh
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter Stagnation`
Expected: PASS (13 tests — 파라미터화 8건 포함)

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Rules/StagnationClassifier.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/StagnationTests.swift
git commit -m "feat: 정체 등급 판정기 추가 (관측 이력 우선, updated 폴백)"
```

---

### Task 5: HygieneCalculator — 위생 점수

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Rules/HygieneCalculator.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/HygieneTests.swift`

**Interfaces:**
- Consumes: `RuleSet`, `WorkflowMap`, `ObservedIssue`
- Produces: `HygieneReport` (`score`, `hp`, `wipCount`, `wipPenalty`, `zombieCount`, `zombiePenalty`, `ghostCount`, `ghostPenalty`, `nextStep`), `enum HygieneNextStep`, `HygieneCalculator(rules:workflow:).evaluate(_:now:) -> HygieneReport`

`hp`는 스펙 §5.5의 마감 방어 지표다(`3 − min(마감 경과 미완료 건수, 3)`). 유령 티켓 집계와 계산 근거가 같으므로 별도 계산기를 두지 않고 같은 리포트에 담는다.

- [ ] **Step 1: 실패하는 테스트 작성**

스펙 §5.3의 "active 12건, 좀비·유령 0건이면 정확히 44점"을 회귀 테스트로 고정한다.

```swift
import Testing
import Foundation
@testable import ArcadeCore

private let now = iso("2026-08-12T00:00:00Z")
private let calc = HygieneCalculator(rules: .default, workflow: demoWorkflow)

/// 좀비 판정을 피하려면 최근에 갱신된 상태여야 한다.
private func activeIssues(_ count: Int) -> [ObservedIssue] {
    (1...count).map {
        issue(key: "DEMO-\($0)", status: "In Progress", updated: now.addingTimeInterval(-days(1)))
    }
}

@Test func measuredBaselineScoresExactly44() {
    let report = calc.evaluate(activeIssues(12), now: now)
    #expect(report.wipCount == 12)
    #expect(report.wipPenalty == 56)   // (12 - 5) * 8
    #expect(report.zombieCount == 0)
    #expect(report.ghostCount == 0)
    #expect(report.score == 44)
}

@Test func atOrBelowWIPLimitThereIsNoPenalty() {
    let report = calc.evaluate(activeIssues(5), now: now)
    #expect(report.wipPenalty == 0)
    #expect(report.score == 100)
}

@Test func staleActiveIssuesCountAsZombies() {
    let fresh = issue(key: "DEMO-1", status: "In Progress", updated: now.addingTimeInterval(-days(1)))
    let zombie = issue(key: "DEMO-2", status: "In Progress", updated: now.addingTimeInterval(-days(9)))
    let report = calc.evaluate([fresh, zombie], now: now)
    #expect(report.zombieCount == 1)
    #expect(report.zombiePenalty == 6)
    #expect(report.score == 94)
}

@Test func onlyActiveStageCanBeAZombie() {
    let idle = issue(key: "DEMO-3", status: "Verifying", updated: now.addingTimeInterval(-days(60)))
    let report = calc.evaluate([idle], now: now)
    #expect(report.zombieCount == 0)
}

@Test func overdueUnfinishedIssuesAreGhosts() {
    let ghost = issue(key: "DEMO-4", status: "To Do",
                      due: now.addingTimeInterval(-days(2)),
                      updated: now)
    let report = calc.evaluate([ghost], now: now)
    #expect(report.ghostCount == 1)
    #expect(report.score == 90)
}

@Test func hpStartsFullAndDropsOnePerOverdueIssue() {
    #expect(calc.evaluate(activeIssues(3), now: now).hp == 3)

    let overdue = (1...2).map {
        issue(key: "DEMO-\($0)", status: "In Progress",
              due: now.addingTimeInterval(-days(1)), updated: now)
    }
    #expect(calc.evaluate(overdue, now: now).hp == 1)
}

@Test func hpNeverGoesBelowZero() {
    let overdue = (1...9).map {
        issue(key: "DEMO-\($0)", status: "In Progress",
              due: now.addingTimeInterval(-days(1)), updated: now)
    }
    #expect(calc.evaluate(overdue, now: now).hp == 0)
}

@Test func doneIssuesAreNeverGhosts() {
    let finished = issue(key: "DEMO-5", status: "Done",
                         due: now.addingTimeInterval(-days(10)),
                         updated: now)
    #expect(calc.evaluate([finished], now: now).ghostCount == 0)
}

@Test func scoreNeverGoesBelowZero() {
    let report = calc.evaluate(activeIssues(60), now: now)
    #expect(report.score == 0)
}

@Test func nextStepPointsAtTheBiggestPenalty() {
    let report = calc.evaluate(activeIssues(12), now: now)
    #expect(report.nextStep == .reduceWIP(to: 5, gain: 56))
}

@Test func unmappedStatusesAreIgnoredNotMiscounted() {
    let unknown = issue(key: "DEMO-6", status: "검토 대기", updated: now.addingTimeInterval(-days(30)))
    let report = calc.evaluate([unknown], now: now)
    #expect(report.score == 100)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter Hygiene`
Expected: FAIL — `cannot find 'HygieneCalculator' in scope`

- [ ] **Step 3: 구현**

```swift
import Foundation

/// 위생 점수를 올리기 위한 다음 한 걸음. 문자열이 아니라 구조화된 값으로 돌려주고
/// 문장으로 만드는 일은 UI가 한다(ArcadeCore는 화면을 모른다).
public enum HygieneNextStep: Sendable, Equatable {
    case reduceWIP(to: Int, gain: Int)
    case touchZombies(count: Int, gain: Int)
    case resolveGhosts(count: Int, gain: Int)
}

public struct HygieneReport: Sendable, Equatable {
    public let score: Int
    /// 마감 방어 지표. 마감이 지난 미완료 티켓 1건마다 1씩 깎이며 0 아래로 내려가지 않는다.
    public let hp: Int
    public let wipCount: Int
    public let wipPenalty: Int
    public let zombieCount: Int
    public let zombiePenalty: Int
    public let ghostCount: Int
    public let ghostPenalty: Int
    public let nextStep: HygieneNextStep?
}

public struct HygieneCalculator: Sendable {
    private let rules: RuleSet
    private let workflow: WorkflowMap

    public init(rules: RuleSet, workflow: WorkflowMap) {
        self.rules = rules
        self.workflow = workflow
    }

    public func evaluate(_ issues: [ObservedIssue], now: Date) -> HygieneReport {
        let staged = issues.compactMap { issue -> (ObservedIssue, Stage)? in
            guard let stage = workflow.stage(for: issue.statusName) else { return nil }
            return (issue, stage)
        }

        let active = staged.filter { $0.1 == .active }
        let wipCount = active.count
        let wipPenalty = max(0, wipCount - rules.wipLimit) * rules.wipPenalty

        let zombieCutoff = now.addingTimeInterval(-Double(rules.zombieDays) * 86_400)
        let zombieCount = active.filter { $0.0.jiraUpdatedAt <= zombieCutoff }.count
        let zombiePenalty = zombieCount * rules.zombiePenalty

        let ghostCount = staged.filter { pair in
            guard pair.1 != .done, let due = pair.0.dueDate else { return false }
            return due < now
        }.count
        let ghostPenalty = ghostCount * rules.ghostPenalty

        let score = max(0, rules.hygieneMaxScore - wipPenalty - zombiePenalty - ghostPenalty)

        var candidates: [(Int, HygieneNextStep)] = []
        if wipPenalty > 0 {
            candidates.append((wipPenalty, .reduceWIP(to: rules.wipLimit, gain: wipPenalty)))
        }
        if zombiePenalty > 0 {
            candidates.append((zombiePenalty, .touchZombies(count: zombieCount, gain: zombiePenalty)))
        }
        if ghostPenalty > 0 {
            candidates.append((ghostPenalty, .resolveGhosts(count: ghostCount, gain: ghostPenalty)))
        }

        return HygieneReport(
            score: score,
            hp: max(0, rules.maxHP - min(ghostCount, rules.maxHP)),
            wipCount: wipCount, wipPenalty: wipPenalty,
            zombieCount: zombieCount, zombiePenalty: zombiePenalty,
            ghostCount: ghostCount, ghostPenalty: ghostPenalty,
            nextStep: candidates.max(by: { $0.0 < $1.0 })?.1
        )
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter Hygiene`
Expected: PASS (11 tests)

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Rules/HygieneCalculator.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/HygieneTests.swift
git commit -m "feat: 위생 점수 계산기 추가 (WIP·좀비·유령 감점)"
```

---

### Task 6: LevelCurve — XP를 레벨로

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Rules/LevelCurve.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/LevelCurveTests.swift`

**Interfaces:**
- Consumes: `RuleSet`
- Produces: `LevelCurve(rules:)`, `threshold(forLevel: Int) -> Int`, `level(forTotalXP: Int) -> Int`, `LevelProgress` (`level`, `xpIntoLevel`, `xpForNextLevel`), `progress(forTotalXP: Int) -> LevelProgress`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import Testing
@testable import ArcadeCore

private let curve = LevelCurve(rules: .default)

@Test(arguments: [(5, 1_812), (10, 6_310), (20, 21_972)])
func thresholdsMatchSpec(level: Int, expected: Int) {
    #expect(curve.threshold(forLevel: level) == expected)
}

@Test func levelOneIsTheFloor() {
    #expect(curve.level(forTotalXP: 0) == 1)
    #expect(curve.level(forTotalXP: 50) == 1)
}

@Test(arguments: [(1_812, 5), (6_310, 10), (21_972, 20)])
func totalXPResolvesToLevel(xp: Int, expected: Int) {
    #expect(curve.level(forTotalXP: xp) == expected)
}

/// threshold와 level은 서로의 역함수여야 한다.
/// 이 불변식이 깨지면 "레벨 20 임계값을 정확히 채웠는데 레벨 19로 표시되는" 상태가 생긴다.
@Test func thresholdAndLevelAreInverse() {
    for n in 1...30 {
        #expect(curve.level(forTotalXP: curve.threshold(forLevel: n)) == n, "레벨 \(n)")
    }
}

@Test func levelIsMonotonicInXP() {
    var last = 0
    for xp in stride(from: 0, through: 25_000, by: 250) {
        let level = curve.level(forTotalXP: xp)
        #expect(level >= last)
        last = level
    }
}

@Test func progressReportsPositionWithinTheLevel() {
    let level5 = curve.threshold(forLevel: 5)
    let level6 = curve.threshold(forLevel: 6)
    let progress = curve.progress(forTotalXP: level5 + 100)
    #expect(progress.level == 5)
    #expect(progress.xpIntoLevel == 100)
    #expect(progress.xpForNextLevel == level6 - level5)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter LevelCurve`
Expected: FAIL — `cannot find 'LevelCurve' in scope`

- [ ] **Step 3: 구현**

```swift
import Foundation

public struct LevelProgress: Sendable, Equatable {
    public let level: Int
    public let xpIntoLevel: Int
    public let xpForNextLevel: Int
}

/// 누적 XP와 레벨의 상호 변환. threshold(n) = base × n^exponent 이며
/// level(xp)는 그 역함수를 내림한 값이다(최소 1).
public struct LevelCurve: Sendable {
    private let rules: RuleSet

    public init(rules: RuleSet) {
        self.rules = rules
    }

    /// 레벨 N에 도달하는 데 필요한 누적 XP.
    /// 반올림이 아니라 **올림**을 쓴다 — 반올림하면 threshold(N)이 실제 임계보다 낮아질 수 있고
    /// (예: 21971.21 → 21971), 그 값을 level()에 넣으면 N-1이 나와 레벨 경계가 어긋난다.
    public func threshold(forLevel level: Int) -> Int {
        guard level > 0 else { return 0 }
        return Int((rules.levelBase * pow(Double(level), rules.levelExponent)).rounded(.up))
    }

    public func level(forTotalXP xp: Int) -> Int {
        guard xp > 0 else { return 1 }
        let raw = pow(Double(xp) / rules.levelBase, 1 / rules.levelExponent)
        // 부동소수 오차로 경계에서 한 단계 낮게 떨어지는 것을 막는다.
        let adjusted = (raw + 1e-9).rounded(.down)
        return max(1, Int(adjusted))
    }

    public func progress(forTotalXP xp: Int) -> LevelProgress {
        let current = level(forTotalXP: xp)
        let floorXP = threshold(forLevel: current)
        let nextXP = threshold(forLevel: current + 1)
        return LevelProgress(
            level: current,
            xpIntoLevel: max(0, xp - floorXP),
            xpForNextLevel: max(1, nextXP - floorXP)
        )
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter LevelCurve`
Expected: PASS (6개 테스트 함수 — 파라미터화 케이스 6건 포함)

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Rules/LevelCurve.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/LevelCurveTests.swift
git commit -m "feat: 레벨 곡선 추가 (100 x N^1.8과 역함수)"
```

---

### Task 7: StreakCalculator — 연속 기록과 동결

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Rules/StreakCalculator.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/StreakTests.swift`

**Interfaces:**
- Consumes: `RuleSet`
- Produces: `StreakState` (`currentStreak`, `longestStreak`, `lastCheckInDay`, `freezesAvailable`, `freezeRefilledWeek`), `StreakCalculator(rules:calendar:)`, `checkIn(_:at:) -> StreakState`, `multiplier(forStreak: Int) -> Double`

- [ ] **Step 1: 실패하는 테스트 작성**

주말 제외와 동결이 얽히므로 케이스를 명시적으로 못박는다. 테스트는 UTC 달력을 쓴다.

```swift
import Testing
import Foundation
@testable import ArcadeCore

private var utc: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private let calc = StreakCalculator(rules: .default, calendar: utc)

// 2026-08-10 월, 08-11 화, 08-12 수, 08-13 목, 08-14 금, 08-15 토, 08-17 월
private func day(_ d: String) -> Date { iso("2026-08-\(d)T09:00:00Z") }

@Test func firstCheckInStartsStreakAtOne() {
    let state = calc.checkIn(StreakState.initial, at: day("10"))
    #expect(state.currentStreak == 1)
    #expect(state.longestStreak == 1)
}

@Test func consecutiveWeekdaysExtendTheStreak() {
    var state = calc.checkIn(StreakState.initial, at: day("10"))
    state = calc.checkIn(state, at: day("11"))
    state = calc.checkIn(state, at: day("12"))
    #expect(state.currentStreak == 3)
}

@Test func secondCheckInSameDayDoesNotDoubleCount() {
    var state = calc.checkIn(StreakState.initial, at: day("10"))
    state = calc.checkIn(state, at: iso("2026-08-10T18:00:00Z"))
    #expect(state.currentStreak == 1)
}

@Test func weekendGapDoesNotBreakTheStreak() {
    var state = calc.checkIn(StreakState.initial, at: day("14"))  // 금
    state = calc.checkIn(state, at: day("17"))                    // 다음 월
    #expect(state.currentStreak == 2)
    #expect(state.freezesAvailable == 1, "주말은 결석이 아니므로 동결을 쓰지 않는다")
}

@Test func oneMissedWeekdayConsumesAFreeze() {
    var state = calc.checkIn(StreakState.initial, at: day("10"))  // 월
    state = calc.checkIn(state, at: day("12"))                    // 수 (화 결석)
    #expect(state.currentStreak == 2)
    #expect(state.freezesAvailable == 0)
}

@Test func missingTwoWeekdaysResetsTheStreak() {
    var state = calc.checkIn(StreakState.initial, at: day("10"))  // 월
    state = calc.checkIn(state, at: day("13"))                    // 목 (화·수 결석)
    #expect(state.currentStreak == 1)
}

@Test func freezeRefillsInANewWeek() {
    var state = calc.checkIn(StreakState.initial, at: day("10"))  // 월
    state = calc.checkIn(state, at: day("12"))                    // 동결 소모
    #expect(state.freezesAvailable == 0)
    state = calc.checkIn(state, at: day("17"))                    // 다음 주 월
    #expect(state.freezesAvailable == 1)
}

@Test func longestStreakRemembersThePeak() {
    var state = calc.checkIn(StreakState.initial, at: day("10"))
    state = calc.checkIn(state, at: day("11"))
    state = calc.checkIn(state, at: day("12"))
    state = calc.checkIn(state, at: day("17"))  // 목·금 결석 → 리셋
    #expect(state.currentStreak == 1)
    #expect(state.longestStreak == 3)
}

@Test(arguments: [(0, 1.0), (1, 1.05), (7, 1.35), (14, 1.70), (30, 1.70)])
func multiplierCapsAtFourteenDays(streak: Int, expected: Double) {
    #expect(abs(calc.multiplier(forStreak: streak) - expected) < 0.0001)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter Streak`
Expected: FAIL — `cannot find 'StreakCalculator' in scope`

- [ ] **Step 3: 구현**

```swift
import Foundation

public struct StreakState: Sendable, Equatable {
    public var currentStreak: Int
    public var longestStreak: Int
    public var lastCheckInDay: Date?
    public var freezesAvailable: Int
    /// 동결을 마지막으로 보충한 주의 시작일. 주가 바뀌면 다시 채운다.
    public var freezeRefilledWeek: Date?

    public init(
        currentStreak: Int = 0, longestStreak: Int = 0, lastCheckInDay: Date? = nil,
        freezesAvailable: Int = 1, freezeRefilledWeek: Date? = nil
    ) {
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.lastCheckInDay = lastCheckInDay
        self.freezesAvailable = freezesAvailable
        self.freezeRefilledWeek = freezeRefilledWeek
    }

    public static let initial = StreakState()
}

public struct StreakCalculator: Sendable {
    private let rules: RuleSet
    private let calendar: Calendar

    public init(rules: RuleSet, calendar: Calendar) {
        self.rules = rules
        self.calendar = calendar
    }

    public func multiplier(forStreak streak: Int) -> Double {
        1 + Double(min(max(streak, 0), rules.streakCapDays)) * rules.streakStepBonus
    }

    public func checkIn(_ state: StreakState, at now: Date) -> StreakState {
        var next = state
        let today = calendar.startOfDay(for: now)

        next = refillFreezeIfNewWeek(next, today: today)

        guard let last = state.lastCheckInDay else {
            next.currentStreak = 1
            next.longestStreak = max(next.longestStreak, 1)
            next.lastCheckInDay = today
            return next
        }

        let lastDay = calendar.startOfDay(for: last)
        if lastDay == today { return next }   // 같은 날 재체크인은 무시

        let missed = countedDaysBetween(lastDay, and: today) - 1

        if missed <= 0 {
            next.currentStreak = state.currentStreak + 1
        } else if missed == 1 && next.freezesAvailable > 0 {
            next.freezesAvailable -= 1
            next.currentStreak = state.currentStreak + 1
        } else {
            next.currentStreak = 1
        }

        next.longestStreak = max(next.longestStreak, next.currentStreak)
        next.lastCheckInDay = today
        return next
    }

    /// 두 날짜 사이의 "세는 날" 수. 주말을 세지 않는 설정이면 토·일은 제외한다.
    /// 같은 날이면 0, 연속한 세는 날이면 1을 돌려준다.
    private func countedDaysBetween(_ from: Date, and to: Date) -> Int {
        guard to > from else { return 0 }
        var count = 0
        var cursor = from
        while cursor < to {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            if isCounted(cursor) { count += 1 }
        }
        return count
    }

    private func isCounted(_ date: Date) -> Bool {
        if rules.countsWeekends { return true }
        return !calendar.isDateInWeekend(date)
    }

    private func refillFreezeIfNewWeek(_ state: StreakState, today: Date) -> StreakState {
        var next = state
        guard let week = calendar.dateInterval(of: .weekOfYear, for: today)?.start else { return next }
        if next.freezeRefilledWeek != week {
            next.freezeRefilledWeek = week
            next.freezesAvailable = 1
        }
        return next
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter Streak`
Expected: PASS (13 tests — 파라미터화 5건 포함)

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Rules/StreakCalculator.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/StreakTests.swift
git commit -m "feat: 연속 기록 계산기 추가 (주말 제외 + 주 1회 동결)"
```

---

### Task 8: XpAwarder — 이벤트 1건의 기본 XP

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Rules/XpAwarder.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/XpAwarderTests.swift`

**Interfaces:**
- Consumes: `RuleSet`, `WorkflowMap`, `StagnationClassifier`, `DomainEvent`, `ObservedIssue`
- Produces: `XpAwarder(rules:workflow:)`, `baseXP(for:issue:statusEnteredAt:now:) -> Int`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import Testing
import Foundation
@testable import ArcadeCore

private let now = iso("2026-08-12T00:00:00Z")
private let awarder = XpAwarder(rules: .default, workflow: demoWorkflow)

private func statusEvent(from: String, to: String) -> DomainEvent {
    DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: from, toStatus: to,
                observedAt: now, actorAccountId: "acc-me")
}

@Test func wakingA21DayBossPaysBaseTimesMultiplier() {
    let event = DomainEvent(issueKey: "DEMO-1", kind: .touched, fromStatus: nil, toStatus: nil,
                            observedAt: now, actorAccountId: "acc-me")
    let xp = awarder.baseXP(for: event,
                            issue: issue(key: "DEMO-1", status: "Verifying"),
                            statusEnteredAt: now.addingTimeInterval(-days(21)),
                            now: now)
    #expect(xp == 100)   // 40 × min(1 + 21/14, 4.0) = 40 × 2.5
}

@Test func wakeMultiplierIsCappedAtFour() {
    let event = DomainEvent(issueKey: "DEMO-1", kind: .touched, fromStatus: nil, toStatus: nil,
                            observedAt: now, actorAccountId: "acc-me")
    let xp = awarder.baseXP(for: event,
                            issue: issue(key: "DEMO-1", status: "Verifying"),
                            statusEnteredAt: now.addingTimeInterval(-days(200)),
                            now: now)
    #expect(xp == 160)   // 40 × 4.0
}

@Test func forwardTransitionGetsTheForwardMultiplier() {
    let xp = awarder.baseXP(for: statusEvent(from: "To Do", to: "In Progress"),
                            issue: issue(key: "DEMO-1", status: "In Progress"),
                            statusEnteredAt: now.addingTimeInterval(-days(21)),
                            now: now)
    #expect(xp == 150)   // 100 × 1.5
}

@Test func backwardTransitionScoresZeroNotNegative() {
    let xp = awarder.baseXP(for: statusEvent(from: "In Progress", to: "To Do"),
                            issue: issue(key: "DEMO-1", status: "To Do"),
                            statusEnteredAt: now.addingTimeInterval(-days(30)),
                            now: now)
    #expect(xp == 0)
}

@Test func finishingBeforeTheDueDatePaysABonus() {
    let xp = awarder.baseXP(
        for: statusEvent(from: "Verifying", to: "Done"),
        issue: issue(key: "DEMO-1", status: "Done", due: now.addingTimeInterval(days(3))),
        statusEnteredAt: now,   // 정체 0일 → 깨우기 XP는 40 × 1.0 × 1.5 = 60
        now: now
    )
    #expect(xp == 90)   // 60 + min(3 × 10, 80)
}

@Test func dueBonusIsCapped() {
    let xp = awarder.baseXP(
        for: statusEvent(from: "Verifying", to: "Done"),
        issue: issue(key: "DEMO-1", status: "Done", due: now.addingTimeInterval(days(60))),
        statusEnteredAt: now,
        now: now
    )
    #expect(xp == 140)   // 60 + 80(상한)
}

@Test func overdueCompletionGetsNoBonusAndNoPenalty() {
    let xp = awarder.baseXP(
        for: statusEvent(from: "Verifying", to: "Done"),
        issue: issue(key: "DEMO-1", status: "Done", due: now.addingTimeInterval(-days(5))),
        statusEnteredAt: now,
        now: now
    )
    #expect(xp == 60)
}

@Test(arguments: [EventKind.appeared, .vanished, .dueDateChanged])
func bookkeepingEventsPayNothing(kind: EventKind) {
    let event = DomainEvent(issueKey: "DEMO-1", kind: kind, fromStatus: nil, toStatus: nil,
                            observedAt: now, actorAccountId: "acc-me")
    let xp = awarder.baseXP(for: event,
                            issue: issue(key: "DEMO-1", status: "Verifying"),
                            statusEnteredAt: now.addingTimeInterval(-days(100)),
                            now: now)
    #expect(xp == 0)
}

@Test func unmappedStatusTransitionScoresZero() {
    let xp = awarder.baseXP(for: statusEvent(from: "검토 대기", to: "보류"),
                            issue: issue(key: "DEMO-1", status: "보류"),
                            statusEnteredAt: now.addingTimeInterval(-days(30)),
                            now: now)
    #expect(xp == 0)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter XpAwarder`
Expected: FAIL — `cannot find 'XpAwarder' in scope`

- [ ] **Step 3: 구현**

```swift
import Foundation

/// 이벤트 한 건의 기본 XP를 계산한다. 중복·상한·되돌림 같은 전체 맥락 조정은 AbuseGuard가 맡는다.
public struct XpAwarder: Sendable {
    private let rules: RuleSet
    private let workflow: WorkflowMap
    private let classifier: StagnationClassifier

    public init(rules: RuleSet, workflow: WorkflowMap) {
        self.rules = rules
        self.workflow = workflow
        self.classifier = StagnationClassifier(rules: rules)
    }

    public func baseXP(
        for event: DomainEvent,
        issue: ObservedIssue,
        statusEnteredAt: Date?,
        now: Date
    ) -> Int {
        switch event.kind {
        case .appeared, .vanished, .dueDateChanged:
            return 0
        case .touched:
            return wakeXP(issue: issue, statusEnteredAt: statusEnteredAt, now: now)
        case .statusChanged:
            return transitionXP(event: event, issue: issue, statusEnteredAt: statusEnteredAt, now: now)
        }
    }

    private func wakeXP(issue: ObservedIssue, statusEnteredAt: Date?, now: Date) -> Int {
        let elapsed = classifier.daysStagnant(
            statusEnteredAt: statusEnteredAt,
            jiraUpdatedAt: issue.jiraUpdatedAt,
            now: now
        )
        let multiplier = min(1 + Double(elapsed) / rules.wakeDivisorDays, rules.wakeMaxMultiplier)
        return Int((Double(rules.wakeBaseXP) * multiplier).rounded())
    }

    private func transitionXP(
        event: DomainEvent, issue: ObservedIssue, statusEnteredAt: Date?, now: Date
    ) -> Int {
        guard
            let from = event.fromStatus.flatMap({ workflow.stage(for: $0) }),
            let to = event.toStatus.flatMap({ workflow.stage(for: $0) })
        else { return 0 }

        guard to.order > from.order else { return 0 }   // 후퇴·수평 이동은 0점(감점 아님)

        let wake = wakeXP(issue: issue, statusEnteredAt: statusEnteredAt, now: now)
        var total = Int((Double(wake) * rules.forwardMultiplier).rounded())

        if to == .done, let due = issue.dueDate, due > now {
            let spareDays = Int(due.timeIntervalSince(now) / 86_400)
            total += min(spareDays * rules.dueBonusPerDay, rules.dueBonusCap)
        }
        return total
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter XpAwarder`
Expected: PASS (11 tests — 파라미터화 3건 포함)

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Rules/XpAwarder.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/XpAwarderTests.swift
git commit -m "feat: 이벤트별 기본 XP 계산기 추가"
```

---

### Task 9: AbuseGuard — 중복·되돌림·일일 상한

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Rules/AbuseGuard.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/AbuseGuardTests.swift`

**Interfaces:**
- Consumes: `RuleSet`, `ScoredEvent`
- Produces: `AbuseGuard(rules:calendar:)`, `apply(to: [ScoredEvent]) -> [ScoredEvent]`

- [ ] **Step 1: 실패하는 테스트 작성**

적용 순서(중복 → 되돌림 → 일일 상한)가 결과를 바꾸므로 테스트로 못박는다.

```swift
import Testing
import Foundation
@testable import ArcadeCore

private var utc: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private let guard_ = AbuseGuard(rules: .default, calendar: utc)

private func scored(_ key: String, from: String?, to: String?, at: Date, xp: Int) -> ScoredEvent {
    ScoredEvent(
        event: DomainEvent(issueKey: key, kind: .statusChanged, fromStatus: from, toStatus: to,
                           observedAt: at, actorAccountId: "acc-me"),
        xp: xp
    )
}

@Test func identicalTransitionWithin24HoursPaysOnce() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.apply(to: [
        scored("DEMO-1", from: "To Do", to: "In Progress", at: base, xp: 100),
        scored("DEMO-1", from: "To Do", to: "In Progress", at: base.addingTimeInterval(hours(3)), xp: 100),
    ])
    #expect(result.map(\.xp) == [100, 0])
}

@Test func identicalTransitionAfter24HoursPaysAgain() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.apply(to: [
        scored("DEMO-1", from: "To Do", to: "In Progress", at: base, xp: 100),
        scored("DEMO-1", from: "To Do", to: "In Progress", at: base.addingTimeInterval(hours(25)), xp: 100),
    ])
    #expect(result.map(\.xp) == [100, 100])
}

@Test func revertingWithin10MinutesVoidsTheOriginalAward() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.apply(to: [
        scored("DEMO-1", from: "In Progress", to: "In Review", at: base, xp: 150),
        scored("DEMO-1", from: "In Review", to: "In Progress", at: base.addingTimeInterval(minutes(4)), xp: 0),
    ])
    #expect(result.map(\.xp) == [0, 0])
}

@Test func revertingAfterTheWindowKeepsTheAward() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.apply(to: [
        scored("DEMO-1", from: "In Progress", to: "In Review", at: base, xp: 150),
        scored("DEMO-1", from: "In Review", to: "In Progress", at: base.addingTimeInterval(minutes(30)), xp: 0),
    ])
    #expect(result.map(\.xp) == [150, 0])
}

@Test func dailyCapTruncatesTheOverflowEvent() {
    let base = iso("2026-08-12T09:00:00Z")
    let events = (1...5).map {
        scored("DEMO-\($0)", from: "To Do", to: "In Progress",
               at: base.addingTimeInterval(minutes(Double($0) * 20)), xp: 300)
    }
    let result = guard_.apply(to: events)
    #expect(result.map(\.xp) == [300, 300, 300, 300, 0])
    #expect(result.reduce(0) { $0 + $1.xp } == 1_200)
}

@Test func dailyCapResetsOnTheNextDay() {
    let day1 = iso("2026-08-12T09:00:00Z")
    let day2 = iso("2026-08-13T09:00:00Z")
    let result = guard_.apply(to: [
        scored("DEMO-1", from: "To Do", to: "In Progress", at: day1, xp: 1_200),
        scored("DEMO-2", from: "To Do", to: "In Progress", at: day2, xp: 500),
    ])
    #expect(result.map(\.xp) == [1_200, 500])
}

@Test func capPartiallyAwardsTheEventThatCrossesTheLimit() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.apply(to: [
        scored("DEMO-1", from: "To Do", to: "In Progress", at: base, xp: 1_000),
        scored("DEMO-2", from: "To Do", to: "In Progress", at: base.addingTimeInterval(hours(1)), xp: 500),
    ])
    #expect(result.map(\.xp) == [1_000, 200])
}

@Test func inputOrderIsPreserved() {
    let base = iso("2026-08-12T09:00:00Z")
    let result = guard_.apply(to: [
        scored("DEMO-9", from: "To Do", to: "In Progress", at: base, xp: 50),
        scored("DEMO-1", from: "To Do", to: "In Progress", at: base.addingTimeInterval(hours(1)), xp: 50),
    ])
    #expect(result.map(\.event.issueKey) == ["DEMO-9", "DEMO-1"])
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter AbuseGuard`
Expected: FAIL — `cannot find 'AbuseGuard' in scope`

- [ ] **Step 3: 구현**

```swift
import Foundation

/// 점수 파밍을 막는 세 가지 조정을 순서대로 적용한다.
/// 입력은 `observedAt` 오름차순으로 정렬되어 있다고 가정하지 않고 내부에서 정렬해 판정하되,
/// 반환 배열의 순서는 입력 순서를 그대로 유지한다.
public struct AbuseGuard: Sendable {
    private let rules: RuleSet
    private let calendar: Calendar

    public init(rules: RuleSet, calendar: Calendar) {
        self.rules = rules
        self.calendar = calendar
    }

    public func apply(to events: [ScoredEvent]) -> [ScoredEvent] {
        var working = events
        let order = working.indices.sorted { working[$0].event.observedAt < working[$1].event.observedAt }

        voidDuplicates(&working, order: order)
        voidReverts(&working, order: order)
        applyDailyCap(&working, order: order)

        return working
    }

    /// 같은 티켓의 동일한 (from → to) 전이가 창 안에서 반복되면 두 번째부터 0점.
    private func voidDuplicates(_ events: inout [ScoredEvent], order: [Int]) {
        var lastAwarded: [String: Date] = [:]
        let window = rules.duplicateWindowHours * 3_600

        for index in order {
            let event = events[index].event
            guard event.kind == .statusChanged, events[index].xp > 0 else { continue }
            let signature = "\(event.issueKey)|\(event.fromStatus ?? "")|\(event.toStatus ?? "")"

            if let previous = lastAwarded[signature],
               event.observedAt.timeIntervalSince(previous) < window {
                events[index].xp = 0
            } else {
                lastAwarded[signature] = event.observedAt
            }
        }
    }

    /// 전이 직후 창 안에서 정확히 역방향 전이가 관측되면 원래 지급분을 회수한다.
    private func voidReverts(_ events: inout [ScoredEvent], order: [Int]) {
        let window = rules.revertWindowMinutes * 60

        for (position, index) in order.enumerated() {
            let later = events[index].event
            guard later.kind == .statusChanged else { continue }

            for earlierIndex in order[..<position].reversed() {
                let earlier = events[earlierIndex].event
                guard earlier.kind == .statusChanged, earlier.issueKey == later.issueKey else { continue }
                guard later.observedAt.timeIntervalSince(earlier.observedAt) <= window else { break }

                if earlier.fromStatus == later.toStatus && earlier.toStatus == later.fromStatus {
                    events[earlierIndex].xp = 0
                    events[index].xp = 0
                    break
                }
            }
        }
    }

    /// 로컬 날짜별 누적이 상한을 넘으면 넘는 만큼만 깎는다(부분 지급).
    private func applyDailyCap(_ events: inout [ScoredEvent], order: [Int]) {
        var spentByDay: [Date: Int] = [:]

        for index in order where events[index].xp > 0 {
            let day = calendar.startOfDay(for: events[index].event.observedAt)
            let spent = spentByDay[day] ?? 0
            let remaining = max(0, rules.dailyXPCap - spent)
            let granted = min(events[index].xp, remaining)
            events[index].xp = granted
            spentByDay[day] = spent + granted
        }
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter AbuseGuard`
Expected: PASS (8 tests)

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Rules/AbuseGuard.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/AbuseGuardTests.swift
git commit -m "feat: 어뷰징 방지 (중복 전이·되돌림·일일 상한)"
```

---

### Task 10: ScoreEngine — 재집계 진입점

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Rules/ScoreEngine.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/ScoreEngineTests.swift`

**Interfaces:**
- Consumes: `RuleSet`, `WorkflowMap`, `XpAwarder`, `AbuseGuard`, `LevelCurve`, `StreakCalculator`, `DomainEvent`, `ObservedIssue`
- Produces: `PlayerSummary` (`totalXP`, `level`, `xpIntoLevel`, `xpForNextLevel`, `streak`), `ScoreEngine(rules:workflow:calendar:)`, `recompute(events:issues:now:) -> (scored: [ScoredEvent], summary: PlayerSummary)`

- [ ] **Step 1: 실패하는 테스트 작성**

멱등성 테스트가 이 태스크의 목적이다. 이것이 깨지면 규칙 실험이 불가능해진다.

```swift
import Testing
import Foundation
@testable import ArcadeCore

private var utc: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private let now = iso("2026-08-20T00:00:00Z")

private func sampleEvents() -> [DomainEvent] {
    [
        DomainEvent(issueKey: "DEMO-1", kind: .appeared, fromStatus: nil, toStatus: "To Do",
                    observedAt: iso("2026-08-10T09:00:00Z"), actorAccountId: "acc-me"),
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "To Do", toStatus: "In Progress",
                    observedAt: iso("2026-08-11T09:00:00Z"), actorAccountId: "acc-me"),
        DomainEvent(issueKey: "DEMO-2", kind: .touched, fromStatus: nil, toStatus: nil,
                    observedAt: iso("2026-08-12T09:00:00Z"), actorAccountId: "acc-me"),
        DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "In Progress", toStatus: "In Review",
                    observedAt: iso("2026-08-13T09:00:00Z"), actorAccountId: "acc-me"),
    ]
}

private func sampleIssues() -> [String: ObservedIssue] {
    [
        "DEMO-1": issue(key: "DEMO-1", status: "In Review", updated: iso("2026-08-13T09:00:00Z")),
        "DEMO-2": issue(key: "DEMO-2", status: "Verifying", updated: iso("2026-08-12T09:00:00Z")),
    ]
}

@Test func recomputeIsIdempotent() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    let first = engine.recompute(events: sampleEvents(), issues: sampleIssues(), now: now)
    let second = engine.recompute(events: sampleEvents(), issues: sampleIssues(), now: now)
    #expect(first.scored == second.scored)
    #expect(first.summary == second.summary)
}

/// 규칙을 바꾸면 재집계 결과가 그에 비례해 달라진다.
///
/// "정확히 2배"를 요구하지 않는 이유: XP는 정수이고 `XpAwarder`가 반올림하므로
/// `round(2x) != 2·round(x)`다. 예컨대 정체 2일 이벤트는 base 40에서 `45.71 → 46`,
/// base 80에서 `91.43 → 91`이 되어 이벤트마다 최대 1XP가 어긋난다.
/// 정수 점수 체계에서 완전한 스케일 선형성은 원리적으로 불가능하다.
///
/// 스펙이 요구하는 "규칙 변경 후 재집계 = 새 규칙으로 처음부터 계산"은
/// ScoreEngine이 누적 상태를 갖지 않는 구조 자체로 보장되며,
/// `recomputeIsIdempotent`가 그 성질을 지킨다.
@Test func changingRulesChangesTheResultProportionally() {
    var doubled = RuleSet.default
    doubled.wakeBaseXP = RuleSet.default.wakeBaseXP * 2

    let base = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
        .recompute(events: sampleEvents(), issues: sampleIssues(), now: now)
    let scaled = ScoreEngine(rules: doubled, workflow: demoWorkflow, calendar: utc)
        .recompute(events: sampleEvents(), issues: sampleIssues(), now: now)

    #expect(base.summary.totalXP > 0, "기준 점수가 0이면 비율 검증이 무의미하다")
    #expect(scaled.summary.totalXP > base.summary.totalXP)

    let ratio = Double(scaled.summary.totalXP) / Double(base.summary.totalXP)
    #expect(abs(ratio - 2.0) < 0.05, "실제 비율 \(ratio)")
}

/// 규칙 변경이 결과에 실제로 반영되는지를 반올림과 무관하게 확인한다.
/// 값의 크기가 아니라 "달라진다"는 사실 자체를 검증하므로 정수 오차의 영향을 받지 않는다.
@Test func changingRulesActuallyChangesScores() {
    var stricter = RuleSet.default
    stricter.forwardMultiplier = 1.0   // 전진 보너스 제거

    let base = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
        .recompute(events: sampleEvents(), issues: sampleIssues(), now: now)
    let changed = ScoreEngine(rules: stricter, workflow: demoWorkflow, calendar: utc)
        .recompute(events: sampleEvents(), issues: sampleIssues(), now: now)

    #expect(changed.summary.totalXP < base.summary.totalXP)
}

@Test func statusEnteredAtComesFromEarlierEventsNotJiraUpdated() {
    // DEMO-1은 08-11에 "In Progress"으로 들어갔고 08-13에 전이했으므로 정체는 2일이다.
    // jiraUpdatedAt(08-13)으로 근사했다면 정체 0일이 되어 XP가 달라진다.
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    let result = engine.recompute(events: sampleEvents(), issues: sampleIssues(), now: now)
    let transition = result.scored.first {
        $0.event.issueKey == "DEMO-1" && $0.event.toStatus == "In Review"
    }
    // 40 × (1 + 2/14) = 45.71 → 46, × 1.5 = 69
    #expect(transition?.xp == 69)
}

@Test func summaryLevelMatchesTheCurve() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    let result = engine.recompute(events: sampleEvents(), issues: sampleIssues(), now: now)
    let curve = LevelCurve(rules: .default)
    #expect(result.summary.level == curve.level(forTotalXP: result.summary.totalXP))
}

@Test func emptyHistoryProducesLevelOne() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    let result = engine.recompute(events: [], issues: [:], now: now)
    #expect(result.summary.totalXP == 0)
    #expect(result.summary.level == 1)
    #expect(result.summary.streak.currentStreak == 0)
}

@Test func eventsAreProcessedInChronologicalOrderRegardlessOfInputOrder() {
    let engine = ScoreEngine(rules: .default, workflow: demoWorkflow, calendar: utc)
    let forward = engine.recompute(events: sampleEvents(), issues: sampleIssues(), now: now)
    let reversed = engine.recompute(events: sampleEvents().reversed(), issues: sampleIssues(), now: now)
    #expect(forward.summary.totalXP == reversed.summary.totalXP)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter ScoreEngine`
Expected: FAIL — `cannot find 'ScoreEngine' in scope`

- [ ] **Step 3: 구현**

```swift
import Foundation

public struct PlayerSummary: Sendable, Equatable {
    public let totalXP: Int
    public let level: Int
    public let xpIntoLevel: Int
    public let xpForNextLevel: Int
    public let streak: StreakState
}

/// 이벤트 로그 전체를 다시 읽어 점수를 계산한다.
/// 누적 갱신을 하지 않고 항상 처음부터 계산하므로, 규칙을 바꿔도 결과가 일관된다.
public struct ScoreEngine: Sendable {
    private let rules: RuleSet
    private let workflow: WorkflowMap
    private let calendar: Calendar
    private let awarder: XpAwarder
    private let abuseGuard: AbuseGuard
    private let curve: LevelCurve
    private let streaks: StreakCalculator

    public init(rules: RuleSet, workflow: WorkflowMap, calendar: Calendar) {
        self.rules = rules
        self.workflow = workflow
        self.calendar = calendar
        self.awarder = XpAwarder(rules: rules, workflow: workflow)
        self.abuseGuard = AbuseGuard(rules: rules, calendar: calendar)
        self.curve = LevelCurve(rules: rules)
        self.streaks = StreakCalculator(rules: rules, calendar: calendar)
    }

    public func recompute(
        events: [DomainEvent],
        issues: [String: ObservedIssue],
        now: Date
    ) -> (scored: [ScoredEvent], summary: PlayerSummary) {
        let ordered = events.sorted { $0.observedAt < $1.observedAt }

        // 각 티켓이 현재 상태에 들어간 시각을 이벤트 순회로 재구성한다.
        var statusEnteredAt: [String: Date] = [:]
        var scored: [ScoredEvent] = []
        scored.reserveCapacity(ordered.count)

        for event in ordered {
            let issue = issues[event.issueKey] ?? placeholder(for: event)
            let xp = awarder.baseXP(
                for: event,
                issue: issue,
                statusEnteredAt: statusEnteredAt[event.issueKey],
                now: event.observedAt
            )
            scored.append(ScoredEvent(event: event, xp: xp))

            if event.kind == .statusChanged {
                statusEnteredAt[event.issueKey] = event.observedAt
            }
        }

        let adjusted = abuseGuard.apply(to: scored)
        let totalXP = adjusted.reduce(0) { $0 + $1.xp }

        var streak = StreakState.initial
        for day in checkInDays(from: adjusted) {
            streak = streaks.checkIn(streak, at: day)
        }

        let progress = curve.progress(forTotalXP: totalXP)
        let summary = PlayerSummary(
            totalXP: totalXP,
            level: progress.level,
            xpIntoLevel: progress.xpIntoLevel,
            xpForNextLevel: progress.xpForNextLevel,
            streak: streak
        )
        return (adjusted, summary)
    }

    /// XP가 붙은 이벤트가 하루에 한 건이라도 있으면 그날은 체크인으로 본다.
    private func checkInDays(from scored: [ScoredEvent]) -> [Date] {
        var seen = Set<Date>()
        var result: [Date] = []
        for item in scored where item.xp > 0 {
            let day = calendar.startOfDay(for: item.event.observedAt)
            if seen.insert(day).inserted { result.append(day) }
        }
        return result.sorted()
    }

    /// 미러에서 사라진 티켓의 과거 이벤트도 점수에 남아야 하므로 최소 정보로 대체한다.
    private func placeholder(for event: DomainEvent) -> ObservedIssue {
        ObservedIssue(
            key: event.issueKey, summary: "", statusName: event.toStatus ?? "",
            issueType: "", priority: nil, assigneeAccountId: event.actorAccountId,
            assigneeName: nil, dueDate: nil, jiraUpdatedAt: event.observedAt
        )
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter ScoreEngine`
Expected: PASS (7개 테스트 함수)

- [ ] **Step 5: 전체 테스트 실행**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS (여기까지 누적 60건 이상)

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Rules/ScoreEngine.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/ScoreEngineTests.swift
git commit -m "feat: 이벤트 로그 재집계 엔진 추가 (멱등성 보장)"
```

---

### Task 11: DiffEngine — 스냅샷 비교로 이벤트 생성

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Sync/DiffEngine.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/DiffEngineTests.swift`

**Interfaces:**
- Consumes: `ObservedIssue`, `DomainEvent`
- Produces: `DiffEngine()`, `diff(previous: [String: ObservedIssue], current: [ObservedIssue], observedAt: Date) -> [DomainEvent]`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import Testing
import Foundation
@testable import ArcadeCore

private let observedAt = iso("2026-08-12T09:00:00Z")
private let engine = DiffEngine()

@Test func newIssueProducesAppeared() {
    let events = engine.diff(previous: [:],
                             current: [issue(key: "DEMO-1", status: "To Do")],
                             observedAt: observedAt)
    #expect(events.count == 1)
    #expect(events[0].kind == .appeared)
    #expect(events[0].toStatus == "To Do")
    #expect(events[0].observedAt == observedAt)
}

@Test func statusChangeCarriesBothEnds() {
    let before = issue(key: "DEMO-1", status: "In Progress", updated: iso("2026-08-11T00:00:00Z"))
    let after = issue(key: "DEMO-1", status: "In Review", updated: iso("2026-08-12T00:00:00Z"))
    let events = engine.diff(previous: ["DEMO-1": before], current: [after], observedAt: observedAt)
    #expect(events.count == 1)
    #expect(events[0].kind == .statusChanged)
    #expect(events[0].fromStatus == "In Progress")
    #expect(events[0].toStatus == "In Review")
}

@Test func updatedTimestampAloneProducesTouched() {
    let before = issue(key: "DEMO-1", status: "Verifying", updated: iso("2026-08-11T00:00:00Z"))
    let after = issue(key: "DEMO-1", status: "Verifying", updated: iso("2026-08-12T00:00:00Z"))
    let events = engine.diff(previous: ["DEMO-1": before], current: [after], observedAt: observedAt)
    #expect(events.map(\.kind) == [.touched])
}

@Test func noChangeProducesNoEvents() {
    let same = issue(key: "DEMO-1", status: "Verifying", updated: iso("2026-08-11T00:00:00Z"))
    let events = engine.diff(previous: ["DEMO-1": same], current: [same], observedAt: observedAt)
    #expect(events.isEmpty)
}

@Test func dueDateChangeIsItsOwnEvent() {
    let before = issue(key: "DEMO-1", status: "In Progress",
                       due: iso("2026-08-20T00:00:00Z"), updated: iso("2026-08-11T00:00:00Z"))
    let after = issue(key: "DEMO-1", status: "In Progress",
                      due: iso("2026-08-25T00:00:00Z"), updated: iso("2026-08-12T00:00:00Z"))
    let events = engine.diff(previous: ["DEMO-1": before], current: [after], observedAt: observedAt)
    #expect(Set(events.map(\.kind)) == [.touched, .dueDateChanged])
}

@Test func statusChangeSuppressesTouched() {
    let before = issue(key: "DEMO-1", status: "In Progress", updated: iso("2026-08-11T00:00:00Z"))
    let after = issue(key: "DEMO-1", status: "Verifying", updated: iso("2026-08-12T00:00:00Z"))
    let events = engine.diff(previous: ["DEMO-1": before], current: [after], observedAt: observedAt)
    #expect(events.map(\.kind) == [.statusChanged], "상태 전이는 그 자체로 갱신이므로 touched를 겹쳐 내지 않는다")
}

@Test func missingIssueProducesVanished() {
    let before = issue(key: "DEMO-1", status: "In Progress")
    let events = engine.diff(previous: ["DEMO-1": before], current: [], observedAt: observedAt)
    #expect(events.map(\.kind) == [.vanished])
    #expect(events[0].fromStatus == "In Progress")
}

@Test func outputOrderIsDeterministic() {
    let previous: [String: ObservedIssue] = [:]
    let current = [
        issue(key: "DEMO-9", status: "In Progress"),
        issue(key: "DEMO-1", status: "In Progress"),
        issue(key: "DEMO-5", status: "In Progress"),
    ]
    let first = engine.diff(previous: previous, current: current, observedAt: observedAt)
    let second = engine.diff(previous: previous, current: current.reversed(), observedAt: observedAt)
    #expect(first.map(\.issueKey) == ["DEMO-1", "DEMO-5", "DEMO-9"])
    #expect(first == second)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter DiffEngine`
Expected: FAIL — `cannot find 'DiffEngine' in scope`

- [ ] **Step 3: 구현**

```swift
import Foundation

/// 직전 미러와 새 조회 결과를 비교해 관측 이벤트를 만든다.
/// 출력은 항상 issueKey 오름차순이라 같은 입력이면 같은 결과가 나온다.
public struct DiffEngine: Sendable {
    public init() {}

    public func diff(
        previous: [String: ObservedIssue],
        current: [ObservedIssue],
        observedAt: Date
    ) -> [DomainEvent] {
        var events: [DomainEvent] = []
        let currentByKey = Dictionary(uniqueKeysWithValues: current.map { ($0.key, $0) })

        for key in currentByKey.keys.sorted() {
            let now = currentByKey[key]!
            guard let before = previous[key] else {
                events.append(DomainEvent(
                    issueKey: key, kind: .appeared, fromStatus: nil, toStatus: now.statusName,
                    observedAt: observedAt, actorAccountId: now.assigneeAccountId
                ))
                continue
            }

            if before.statusName != now.statusName {
                events.append(DomainEvent(
                    issueKey: key, kind: .statusChanged,
                    fromStatus: before.statusName, toStatus: now.statusName,
                    observedAt: observedAt, actorAccountId: now.assigneeAccountId
                ))
            } else if before.jiraUpdatedAt != now.jiraUpdatedAt {
                events.append(DomainEvent(
                    issueKey: key, kind: .touched, fromStatus: nil, toStatus: nil,
                    observedAt: observedAt, actorAccountId: now.assigneeAccountId
                ))
            }

            if before.dueDate != now.dueDate {
                events.append(DomainEvent(
                    issueKey: key, kind: .dueDateChanged, fromStatus: nil, toStatus: nil,
                    observedAt: observedAt, actorAccountId: now.assigneeAccountId
                ))
            }
        }

        for key in previous.keys.sorted() where currentByKey[key] == nil {
            let before = previous[key]!
            events.append(DomainEvent(
                issueKey: key, kind: .vanished, fromStatus: before.statusName, toStatus: nil,
                observedAt: observedAt, actorAccountId: before.assigneeAccountId
            ))
        }

        return events
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter DiffEngine`
Expected: PASS (8 tests)

- [ ] **Step 5: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Sync/DiffEngine.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/DiffEngineTests.swift
git commit -m "feat: 스냅샷 diff로 관측 이벤트 생성"
```

---

### Task 12: JiraKit 인증 — AuthProvider와 Basic auth

**Files:**
- Create: `Packages/Jirarcade/Sources/JiraKit/AuthProvider.swift`
- Create: `Packages/Jirarcade/Sources/JiraKit/APITokenAuth.swift`
- Create: `Packages/Jirarcade/Tests/JiraKitTests/AuthTests.swift`
- Modify: `Packages/Jirarcade/Package.swift` (`JiraKitTests` 타깃 추가)

**Interfaces:**
- Consumes: 없음
- Produces: `protocol AuthProvider` (`baseURL`, `authorize(_:)`, `recoverFromUnauthorized()`), `APITokenAuth(site:email:token:)`

- [ ] **Step 1: `JiraKitTests` 타깃 추가와 실패하는 테스트 작성**

Task 1의 `Package.swift`에는 `JiraKitTests` 타깃이 없다 — 소스 파일이 하나도 없는 타깃은 빌드 경고를 내기 때문이다. 이 태스크가 첫 JiraKit 테스트를 만드므로 지금 `targets:` 배열의 `ArcadeCoreTests` 앞에 추가한다.

```swift
.testTarget(name: "JiraKitTests", dependencies: ["JiraKit"]),
```

이어서 테스트를 작성한다.

```swift
import Testing
import Foundation
@testable import JiraKit

private let auth = APITokenAuth(site: "example.atlassian.net",
                                email: "user@example.com",
                                token: "secret-token")

@Test func baseURLUsesTheSiteHost() {
    #expect(auth.baseURL.absoluteString == "https://example.atlassian.net/rest/api/3")
}

@Test func siteAcceptsAFullURLAndNormalizesIt() {
    let fromURL = APITokenAuth(site: "https://example.atlassian.net/",
                               email: "user@example.com", token: "t")
    #expect(fromURL.baseURL.absoluteString == "https://example.atlassian.net/rest/api/3")
}

@Test func authorizeSetsBasicHeader() async throws {
    var request = URLRequest(url: URL(string: "https://example.com")!)
    try await auth.authorize(&request)

    let expected = Data("user@example.com:secret-token".utf8).base64EncodedString()
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic \(expected)")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
}

@Test func apiTokenCannotRecoverFromUnauthorized() async throws {
    let recovered = try await auth.recoverFromUnauthorized()
    #expect(recovered == false, "토큰은 갱신할 수 없으므로 재로그인이 필요하다")
}

/// 전역 제약은 토큰과 이메일을 **둘 다** 금지한다.
/// 둘 다 검사해야 나중에 누가 디버깅 편의로 `description`에 이메일을 넣을 때 걸린다.
@Test func descriptionNeverLeaksCredentials() {
    let text = String(describing: auth)
    #expect(!text.contains("secret-token"))
    #expect(!text.contains("user@example.com"))
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter Auth`
Expected: FAIL — `cannot find 'APITokenAuth' in scope`

- [ ] **Step 3: `AuthProvider` 구현**

```swift
import Foundation

/// 인증 헤더와 베이스 URL을 함께 만든다.
/// Basic auth는 https://{site}/rest/api/3 을, OAuth 3LO는
/// https://api.atlassian.com/ex/jira/{cloudId}/rest/api/3 을 쓰므로 둘 다 이 프로토콜 뒤에 숨긴다.
public protocol AuthProvider: Sendable {
    var baseURL: URL { get }
    func authorize(_ request: inout URLRequest) async throws
    /// 401을 만났을 때 자격증명을 갱신할 수 있으면 true. 갱신 후 호출부가 요청을 재시도한다.
    func recoverFromUnauthorized() async throws -> Bool
}
```

- [ ] **Step 4: `APITokenAuth` 구현**

`CustomStringConvertible`을 직접 구현해 토큰이 로그에 새지 않게 한다.

```swift
import Foundation

public struct APITokenAuth: AuthProvider, CustomStringConvertible {
    private let host: String
    private let email: String
    private let token: String

    /// site는 "example.atlassian.net" 또는 전체 URL 어느 쪽이든 받는다.
    public init(site: String, email: String, token: String) {
        self.host = Self.normalizeHost(site)
        self.email = email
        self.token = token
    }

    public var baseURL: URL {
        URL(string: "https://\(host)/rest/api/3")!
    }

    public func authorize(_ request: inout URLRequest) async throws {
        let credentials = Data("\(email):\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    public func recoverFromUnauthorized() async throws -> Bool { false }

    public var description: String { "APITokenAuth(host: \(host))" }

    private static func normalizeHost(_ site: String) -> String {
        var text = site.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter Auth`
Expected: PASS (5 tests)

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/JiraKit/ Packages/Jirarcade/Tests/JiraKitTests/
git commit -m "feat: AuthProvider 추상화와 API Token 구현체 추가"
```

---

### Task 13: JiraKit 디코딩 — 부분 실패를 허용하는 응답 파싱

**Files:**
- Create: `Packages/Jirarcade/Sources/JiraKit/DTO.swift`
- Create: `Packages/Jirarcade/Tests/JiraKitTests/DecodingTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces: `JiraIssue` (`key`, `summary`, `statusName`, `issueType`, `priority`, `assigneeAccountId`, `assigneeName`, `dueDate`, `updated`), `JiraTransition` (`id`, `name`, `toStatusName`), `JiraUser` (`accountId`, `displayName`), `IssuePage` (`issues`, `failures`, `nextPageToken`), `JiraSearchResponse.decode(_:) -> IssuePage`

- [ ] **Step 1: 실패하는 테스트 작성**

50건 중 1건이 깨져도 49건이 살아남아야 한다는 것이 이 태스크의 핵심이다.

```swift
import Testing
import Foundation
@testable import JiraKit

private func json(_ text: String) -> Data { Data(text.utf8) }

private let goodIssue = """
{
  "key": "DEMO-9613",
  "fields": {
    "summary": "[통합/태블릿] 화면 A에서 버튼 추가",
    "status": { "name": "In Progress" },
    "issuetype": { "name": "개선" },
    "priority": { "name": "Medium" },
    "assignee": { "accountId": "acc-me", "displayName": "bahn" },
    "duedate": "2026-08-14",
    "updated": "2026-08-12T15:04:05.000+0900"
  }
}
"""

@Test func decodesARealisticIssue() throws {
    let page = try JiraSearchResponse.decode(json("""
    { "issues": [\(goodIssue)] }
    """))
    #expect(page.issues.count == 1)
    let issue = page.issues[0]
    #expect(issue.key == "DEMO-9613")
    #expect(issue.statusName == "In Progress")
    #expect(issue.issueType == "개선")
    #expect(issue.assigneeName == "bahn")
    #expect(issue.dueDate != nil)
}

@Test func nullAssigneeAndMissingDueDateAreTolerated() throws {
    let page = try JiraSearchResponse.decode(json("""
    { "issues": [{
        "key": "DEMO-1",
        "fields": {
          "summary": "담당자 없음",
          "status": { "name": "To Do" },
          "issuetype": { "name": "버그" },
          "priority": null,
          "assignee": null,
          "updated": "2026-08-12T15:04:05.000+0900"
        }
    }] }
    """))
    #expect(page.issues.count == 1)
    #expect(page.issues[0].assigneeAccountId == nil)
    #expect(page.issues[0].dueDate == nil)
    #expect(page.issues[0].priority == nil)
}

@Test func oneBrokenIssueDoesNotDiscardTheOthers() throws {
    let broken = """
    { "key": "DEMO-BAD", "fields": { "summary": "상태 필드가 없음" } }
    """
    let page = try JiraSearchResponse.decode(json("""
    { "issues": [\(goodIssue), \(broken), \(goodIssue)] }
    """))
    #expect(page.issues.count == 2)
    #expect(page.failures.count == 1)
}

@Test func nextPageTokenIsCarriedThrough() throws {
    let page = try JiraSearchResponse.decode(json("""
    { "issues": [], "nextPageToken": "tok-2" }
    """))
    #expect(page.nextPageToken == "tok-2")
}

@Test func jiraTimestampsParseWithMillisecondsAndOffset() throws {
    let page = try JiraSearchResponse.decode(json("{ \"issues\": [\(goodIssue)] }"))
    let expected = ISO8601DateFormatter().date(from: "2026-08-12T06:04:05Z")!
    #expect(abs(page.issues[0].updated.timeIntervalSince(expected)) < 1)
}

@Test func malformedTopLevelJSONThrows() {
    #expect(throws: (any Error).self) {
        try JiraSearchResponse.decode(json("not json at all"))
    }
}

@Test func transitionsDecode() throws {
    let transitions = try JiraTransition.decodeList(json("""
    { "transitions": [
        { "id": "21", "name": "In Review", "to": { "name": "In Review" } }
    ] }
    """))
    #expect(transitions.count == 1)
    #expect(transitions[0].id == "21")
    #expect(transitions[0].toStatusName == "In Review")
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter Decoding`
Expected: FAIL — `cannot find 'JiraSearchResponse' in scope`

- [ ] **Step 3: 구현**

```swift
import Foundation

public struct JiraIssue: Sendable, Equatable {
    public let key: String
    public let summary: String
    public let statusName: String
    public let issueType: String
    public let priority: String?
    public let assigneeAccountId: String?
    public let assigneeName: String?
    public let dueDate: Date?
    public let updated: Date
}

public struct JiraTransition: Sendable, Equatable, Decodable {
    public let id: String
    public let name: String
    public let toStatusName: String

    private enum CodingKeys: String, CodingKey { case id, name, to }
    private struct StatusRef: Decodable { let name: String }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        toStatusName = try container.decode(StatusRef.self, forKey: .to).name
    }

    public static func decodeList(_ data: Data) throws -> [JiraTransition] {
        struct Envelope: Decodable { let transitions: [JiraTransition] }
        return try JSONDecoder().decode(Envelope.self, from: data).transitions
    }
}

public struct JiraUser: Sendable, Equatable, Decodable {
    public let accountId: String
    public let displayName: String
}

public struct DecodingFailure: Sendable, Equatable {
    public let index: Int
    public let reason: String
}

public struct IssuePage: Sendable, Equatable {
    public let issues: [JiraIssue]
    public let failures: [DecodingFailure]
    public let nextPageToken: String?
}

/// 검색 응답을 파싱한다. 개별 이슈의 디코딩 실패가 전체를 무효화하지 않는다.
public enum JiraSearchResponse {
    public static func decode(_ data: Data) throws -> IssuePage {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)

        var issues: [JiraIssue] = []
        var failures: [DecodingFailure] = []
        for (index, element) in envelope.issues.enumerated() {
            if let value = element.value {
                issues.append(value)
            } else {
                failures.append(DecodingFailure(index: index, reason: element.reason ?? "unknown"))
            }
        }
        return IssuePage(issues: issues, failures: failures, nextPageToken: envelope.nextPageToken)
    }

    private struct Envelope: Decodable {
        let issues: [Failable<JiraIssue>]
        let nextPageToken: String?
    }

    /// 요소 하나가 실패해도 배열 전체를 버리지 않게 감싸는 래퍼.
    private struct Failable<T: Decodable>: Decodable {
        let value: T?
        let reason: String?

        init(from decoder: any Decoder) throws {
            do {
                value = try T(from: decoder)
                reason = nil
            } catch {
                value = nil
                reason = String(describing: error)
            }
        }
    }

}

extension JiraSearchResponse {
    fileprivate static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    fileprivate static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
```

- [ ] **Step 4: `JiraIssue`의 디코딩과 public 이니셜라이저 구현**

Step 3의 `Envelope`이 `Failable<JiraIssue>`를 쓰므로 `JiraIssue`가 직접 Jira 응답 형태를 읽는다.
`init(from:)`을 extension에 두면 memberwise 이니셜라이저가 사라지지 않지만 접근 수준이 internal이므로, 테스트와 Task 15가 쓸 public 이니셜라이저를 함께 정의한다.

```swift
extension JiraIssue: Decodable {
    private enum CodingKeys: String, CodingKey { case key, fields }
    private enum FieldKeys: String, CodingKey {
        case summary, status, issuetype, priority, assignee, duedate, updated
    }
    private struct Named: Decodable { let name: String }
    private struct Person: Decodable { let accountId: String; let displayName: String }

    public init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        key = try root.decode(String.self, forKey: .key)

        let fields = try root.nestedContainer(keyedBy: FieldKeys.self, forKey: .fields)
        summary = try fields.decode(String.self, forKey: .summary)
        statusName = try fields.decode(Named.self, forKey: .status).name
        issueType = try fields.decode(Named.self, forKey: .issuetype).name
        priority = try fields.decodeIfPresent(Named.self, forKey: .priority)?.name

        let person = try fields.decodeIfPresent(Person.self, forKey: .assignee)
        assigneeAccountId = person?.accountId
        assigneeName = person?.displayName

        if let raw = try fields.decodeIfPresent(String.self, forKey: .duedate) {
            dueDate = JiraSearchResponse.dateOnlyFormatter.date(from: raw)
        } else {
            dueDate = nil
        }

        let rawUpdated = try fields.decode(String.self, forKey: .updated)
        guard let parsed = JiraSearchResponse.timestampFormatter.date(from: rawUpdated) else {
            throw DecodingError.dataCorruptedError(
                forKey: .updated, in: fields, debugDescription: "알 수 없는 시각 형식"
            )
        }
        updated = parsed
    }

    /// 테스트와 ArcadeCore의 ObservedIssue 변환이 쓰는 public 이니셜라이저.
    public init(
        key: String, summary: String, statusName: String, issueType: String,
        priority: String?, assigneeAccountId: String?, assigneeName: String?,
        dueDate: Date?, updated: Date
    ) {
        self.key = key
        self.summary = summary
        self.statusName = statusName
        self.issueType = issueType
        self.priority = priority
        self.assigneeAccountId = assigneeAccountId
        self.assigneeName = assigneeName
        self.dueDate = dueDate
        self.updated = updated
    }
}
```

> Jira는 `2026-08-12T15:04:05.000+0900` 형태를 보내므로 `.withFractionalSeconds`가 필요하다. 소수점 없는 응답을 만나면 이 포맷터가 nil을 돌려주고 해당 이슈만 `failures`로 빠진다 — 전체 동기화는 계속된다.

**Swift 6 strict concurrency 대응 (구현 중 확인됨).** 위 코드를 그대로 옮기면 두 곳에서 컴파일되지 않는다:

- `public init(...)`(memberwise)을 extension에 두면 컴파일러가 합성한 internal memberwise 이니셜라이저와 재선언 충돌이 난다. **`JiraIssue` struct 본체 안에** 넣어야 한다.
- `ISO8601DateFormatter`는 `Sendable`을 준수하지 않아 그대로 `static let`으로 둘 수 없다. 설정 후 변경 없이 포맷팅에만 쓰므로 `nonisolated(unsafe) static let`으로 선언하고 그 근거를 주석으로 남긴다. (`DateFormatter`는 `Sendable`을 준수하므로 이 표시가 불필요하다 — 두 포맷터의 선언이 다른 이유다.)

- [ ] **Step 5: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter Decoding`
Expected: PASS (7 tests)

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/JiraKit/DTO.swift \
        Packages/Jirarcade/Tests/JiraKitTests/DecodingTests.swift
git commit -m "feat: 부분 실패를 허용하는 Jira 응답 디코딩"
```

---

### Task 14: JiraKit 에러 매핑과 JiraClient

**Files:**
- Create: `Packages/Jirarcade/Sources/JiraKit/JiraError.swift`
- Create: `Packages/Jirarcade/Sources/JiraKit/JiraClient.swift`
- Create: `Packages/Jirarcade/Tests/JiraKitTests/StubHTTPClient.swift`
- Create: `Packages/Jirarcade/Tests/JiraKitTests/ErrorMappingTests.swift`

**Interfaces:**
- Consumes: `HTTPClient` (Task 1), `AuthProvider` (Task 12), `IssuePage`·`JiraTransition`·`JiraUser` (Task 13)
- Produces: `enum JiraError`, `JiraClient(auth:http:)`, `searchIssues(jql:fields:maxResults:pageToken:) async throws -> IssuePage`, `transitions(issueKey:) async throws -> [JiraTransition]`, `performTransition(issueKey:transitionId:) async throws`, `myself() async throws -> JiraUser`

- [ ] **Step 1: 스텁 HTTP 클라이언트 작성**

```swift
import Foundation
@testable import JiraKit

/// 미리 정한 응답을 순서대로 돌려주는 테스트용 클라이언트.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Response { let status: Int; let body: Data; let headers: [String: String] }

    private var queue: [Response]
    private(set) var sentRequests: [URLRequest] = []
    private let lock = NSLock()

    init(_ responses: [Response]) { self.queue = responses }

    convenience init(status: Int, body: String = "{}", headers: [String: String] = [:]) {
        self.init([Response(status: status, body: Data(body.utf8), headers: headers)])
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        sentRequests.append(request)
        guard !queue.isEmpty else { throw URLError(.badServerResponse) }
        let next = queue.removeFirst()
        let http = HTTPURLResponse(
            url: request.url!, statusCode: next.status,
            httpVersion: nil, headerFields: next.headers
        )!
        return (next.body, http)
    }
}
```

- [ ] **Step 2: 실패하는 테스트 작성**

```swift
import Testing
import Foundation
@testable import JiraKit

private let auth = APITokenAuth(site: "example.atlassian.net", email: "u@e.com", token: "t")

@Test func searchSendsJQLAndAuthorization() async throws {
    let stub = StubHTTPClient(status: 200, body: #"{"issues":[]}"#)
    let client = JiraClient(auth: auth, http: stub)
    _ = try await client.searchIssues(jql: "assignee = currentUser()", fields: ["summary"],
                                      maxResults: 50, pageToken: nil)

    let request = try #require(stub.sentRequests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString.hasSuffix("/search/jql") == true)
    #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)

    let body = try #require(request.httpBody)
    let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    #expect(payload?["jql"] as? String == "assignee = currentUser()")
}

@Test func unauthorizedMapsToJiraError() async {
    let client = JiraClient(auth: auth, http: StubHTTPClient(status: 401))
    await #expect(throws: JiraError.unauthorized) {
        _ = try await client.myself()
    }
}

@Test func rateLimitCarriesRetryAfter() async {
    let stub = StubHTTPClient(status: 429, headers: ["Retry-After": "42"])
    let client = JiraClient(auth: auth, http: stub)
    await #expect(throws: JiraError.rateLimited(retryAfter: 42)) {
        _ = try await client.myself()
    }
}

@Test func serverErrorMapsToServerCase() async {
    let client = JiraClient(auth: auth, http: StubHTTPClient(status: 503))
    await #expect(throws: JiraError.server(status: 503)) {
        _ = try await client.myself()
    }
}

@Test func transitionRejectionSurfacesJiraMessage() async {
    let body = #"{"errorMessages":["전이가 허용되지 않습니다"],"errors":{}}"#
    let stub = StubHTTPClient(status: 400, body: body)
    let client = JiraClient(auth: auth, http: stub)
    await #expect(throws: JiraError.transitionRejected(reason: "전이가 허용되지 않습니다")) {
        try await client.performTransition(issueKey: "DEMO-1", transitionId: "21")
    }
}

@Test func offlineURLErrorIsTranslated() async {
    struct OfflineClient: HTTPClient {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw URLError(.notConnectedToInternet)
        }
    }
    let client = JiraClient(auth: auth, http: OfflineClient())
    await #expect(throws: JiraError.offline) {
        _ = try await client.myself()
    }
}

@Test func successfulTransitionSendsTheTransitionId() async throws {
    let stub = StubHTTPClient(status: 204, body: "")
    let client = JiraClient(auth: auth, http: stub)
    try await client.performTransition(issueKey: "DEMO-1", transitionId: "21")

    let request = try #require(stub.sentRequests.first)
    #expect(request.url?.absoluteString.hasSuffix("/issue/DEMO-1/transitions") == true)
    let payload = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
    let transition = payload?["transition"] as? [String: Any]
    #expect(transition?["id"] as? String == "21")
}
```

- [ ] **Step 3: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter ErrorMapping`
Expected: FAIL — `cannot find 'JiraClient' in scope`

- [ ] **Step 4: `JiraError` 구현**

```swift
import Foundation

public enum JiraError: Error, Equatable, Sendable {
    case offline
    case unauthorized
    case forbidden(resource: String)
    case notFound(key: String)
    case rateLimited(retryAfter: TimeInterval)
    case transitionRejected(reason: String)
    case server(status: Int)
    case decoding(context: String)
}
```

- [ ] **Step 5: `JiraClient` 구현**

```swift
import Foundation

public struct JiraClient: Sendable {
    private let auth: any AuthProvider
    private let http: any HTTPClient

    public init(auth: any AuthProvider, http: any HTTPClient) {
        self.auth = auth
        self.http = http
    }

    public func myself() async throws -> JiraUser {
        let data = try await perform(method: "GET", path: "/myself", body: nil, resource: "myself")
        return try decode(JiraUser.self, from: data)
    }

    public func searchIssues(
        jql: String, fields: [String], maxResults: Int, pageToken: String?
    ) async throws -> IssuePage {
        var payload: [String: Any] = ["jql": jql, "fields": fields, "maxResults": maxResults]
        if let pageToken { payload["nextPageToken"] = pageToken }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await perform(method: "POST", path: "/search/jql", body: body, resource: "search")
        do {
            return try JiraSearchResponse.decode(data)
        } catch {
            throw JiraError.decoding(context: "search: \(error)")
        }
    }

    public func transitions(issueKey: String) async throws -> [JiraTransition] {
        let data = try await perform(method: "GET", path: "/issue/\(issueKey)/transitions",
                                     body: nil, resource: issueKey)
        do {
            return try JiraTransition.decodeList(data)
        } catch {
            throw JiraError.decoding(context: "transitions: \(error)")
        }
    }

    public func performTransition(issueKey: String, transitionId: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["transition": ["id": transitionId]])
        _ = try await perform(method: "POST", path: "/issue/\(issueKey)/transitions",
                              body: body, resource: issueKey)
    }

    // MARK: - 요청 실행

    private func perform(method: String, path: String, body: Data?, resource: String) async throws -> Data {
        var request = URLRequest(url: auth.baseURL.appendingPathComponent(path.dropFirstSlash))
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        try await auth.authorize(&request)

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.send(request)
        } catch let error as URLError {
            throw error.code == .notConnectedToInternet || error.code == .networkConnectionLost
                ? JiraError.offline
                : JiraError.server(status: -1)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapError(status: response.statusCode, data: data,
                                response: response, resource: resource)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw JiraError.decoding(context: "\(type): \(error)")
        }
    }

    static func mapError(
        status: Int, data: Data, response: HTTPURLResponse, resource: String
    ) -> JiraError {
        switch status {
        case 400:  return .transitionRejected(reason: firstErrorMessage(in: data) ?? "요청이 거부되었습니다")
        case 401:  return .unauthorized
        case 403:  return .forbidden(resource: resource)
        case 404:  return .notFound(key: resource)
        case 429:
            let header = response.value(forHTTPHeaderField: "Retry-After")
            return .rateLimited(retryAfter: TimeInterval(header ?? "") ?? 60)
        default:   return .server(status: status)
        }
    }

    private static func firstErrorMessage(in data: Data) -> String? {
        struct Envelope: Decodable { let errorMessages: [String]? }
        return try? JSONDecoder().decode(Envelope.self, from: data).errorMessages?.first
    }
}

private extension String {
    /// URL.appendingPathComponent가 선행 슬래시를 이중으로 만들지 않게 다듬는다.
    var dropFirstSlash: String { hasPrefix("/") ? String(dropFirst()) : self }
}
```

- [ ] **Step 6: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter ErrorMapping`
Expected: PASS (7 tests)

- [ ] **Step 7: 커밋**

```bash
git add Packages/Jirarcade/Sources/JiraKit/ Packages/Jirarcade/Tests/JiraKitTests/
git commit -m "feat: JiraClient와 HTTP 상태 코드 → 도메인 에러 매핑"
```

---

### Task 15: ObservedIssue 변환 — JiraKit DTO를 ArcadeCore 값 타입으로

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Domain/ObservedIssue.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/IssueConversionTests.swift`

**Interfaces:**
- Consumes: `JiraIssue` (Task 13), `ObservedIssue` (Task 3)
- Produces: `ObservedIssue.init(_ jira: JiraIssue)`

의존 방향이 `ArcadeCore → JiraKit`이므로 변환은 반드시 `ArcadeCore` 쪽에 둔다. `JiraKit`이 `ObservedIssue`를 아는 순간 순환 의존이 되어 컴파일이 실패한다.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import Testing
import Foundation
import JiraKit
@testable import ArcadeCore

@Test func convertsEveryFieldFromTheDTO() {
    let due = iso("2026-08-14T00:00:00Z")
    let updated = iso("2026-08-12T06:04:05Z")
    let dto = JiraIssue(
        key: "DEMO-9613", summary: "버튼 추가", statusName: "In Progress", issueType: "개선",
        priority: "Medium", assigneeAccountId: "acc-me", assigneeName: "bahn",
        dueDate: due, updated: updated
    )

    let observed = ObservedIssue(dto)

    #expect(observed.key == "DEMO-9613")
    #expect(observed.summary == "버튼 추가")
    #expect(observed.statusName == "In Progress")
    #expect(observed.issueType == "개선")
    #expect(observed.priority == "Medium")
    #expect(observed.assigneeAccountId == "acc-me")
    #expect(observed.assigneeName == "bahn")
    #expect(observed.dueDate == due)
    #expect(observed.jiraUpdatedAt == updated)
}

@Test func optionalFieldsSurviveAsNil() {
    let dto = JiraIssue(
        key: "DEMO-1", summary: "무담당", statusName: "To Do", issueType: "버그",
        priority: nil, assigneeAccountId: nil, assigneeName: nil,
        dueDate: nil, updated: iso("2026-08-12T00:00:00Z")
    )
    let observed = ObservedIssue(dto)
    #expect(observed.priority == nil)
    #expect(observed.assigneeAccountId == nil)
    #expect(observed.dueDate == nil)
}
```

- [ ] **Step 2: `JiraIssue`의 public 이니셜라이저 확인**

Task 13 Step 4에서 이미 추가했다. 없다면 그 코드를 지금 넣는다 — 테스트가 DTO를 직접 만들 수 있어야 한다.

Run: `cd Packages/Jirarcade && grep -n "public init(" Sources/JiraKit/DTO.swift`
Expected: `JiraIssue`의 public 이니셜라이저 시그니처가 출력된다

- [ ] **Step 3: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter IssueConversion`
Expected: FAIL — `ObservedIssue`에 `JiraIssue`를 받는 이니셜라이저가 없음

- [ ] **Step 4: 변환 구현**

`ObservedIssue.swift` 하단에 추가한다.

```swift
import JiraKit

extension ObservedIssue {
    /// JiraKit DTO를 규칙 엔진이 쓰는 값 타입으로 옮긴다.
    /// 상태명은 조직 커스텀 값 그대로 보존하며 여기서 단계로 바꾸지 않는다.
    public init(_ jira: JiraIssue) {
        self.init(
            key: jira.key,
            summary: jira.summary,
            statusName: jira.statusName,
            issueType: jira.issueType,
            priority: jira.priority,
            assigneeAccountId: jira.assigneeAccountId,
            assigneeName: jira.assigneeName,
            dueDate: jira.dueDate,
            jiraUpdatedAt: jira.updated
        )
    }
}
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter IssueConversion`
Expected: PASS (2 tests)

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Domain/ObservedIssue.swift \
        Packages/Jirarcade/Sources/JiraKit/DTO.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/IssueConversionTests.swift
git commit -m "feat: JiraIssue를 ObservedIssue로 변환 (ArcadeCore 방향 유지)"
```

---

### Task 16: SwiftData 저장소 — 미러와 이벤트 로그 영속화

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Store/StoreModels.swift`
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Store/ArcadeStore.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/StoreTests.swift`

**Interfaces:**
- Consumes: `ObservedIssue`, `DomainEvent`
- Produces: `@Model IssueSnapshot`·`IssueEventRecord`·`SyncRunRecord`, `ArcadeStore(container:)`, `loadMirror() throws -> [String: ObservedIssue]`, `applySync(issues:events:observedAt:) throws`, `loadEvents() throws -> [DomainEvent]`, `beginSyncRun(at:) throws -> PersistentIdentifier`, `finishSyncRun(_:at:issueCount:failure:) throws`, `observationDayCount(now:) throws -> Int`, `ArcadeStore.makeInMemoryContainer() throws -> ModelContainer`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import Testing
import Foundation
import SwiftData
@testable import ArcadeCore

private func makeStore() throws -> ArcadeStore {
    ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
}

@Test func mirrorRoundTripsThroughSwiftData() throws {
    let store = try makeStore()
    let now = iso("2026-08-12T09:00:00Z")
    let one = issue(key: "DEMO-1", status: "In Progress", due: iso("2026-08-20T00:00:00Z"))

    try store.applySync(issues: [one], events: [], observedAt: now)
    let mirror = try store.loadMirror()

    #expect(mirror.count == 1)
    #expect(mirror["DEMO-1"] == one)
}

@Test func syncUpdatesExistingRowsInsteadOfDuplicating() throws {
    let store = try makeStore()
    let day1 = iso("2026-08-11T09:00:00Z")
    let day2 = iso("2026-08-12T09:00:00Z")

    try store.applySync(issues: [issue(key: "DEMO-1", status: "In Progress", updated: day1)],
                        events: [], observedAt: day1)
    try store.applySync(issues: [issue(key: "DEMO-1", status: "Verifying", updated: day2)],
                        events: [], observedAt: day2)

    let mirror = try store.loadMirror()
    #expect(mirror.count == 1)
    #expect(mirror["DEMO-1"]?.statusName == "Verifying")
}

@Test func issuesAbsentFromTheSyncAreRemovedFromTheMirror() throws {
    let store = try makeStore()
    let now = iso("2026-08-12T09:00:00Z")
    try store.applySync(issues: [issue(key: "DEMO-1", status: "In Progress"),
                                 issue(key: "DEMO-2", status: "In Progress")],
                        events: [], observedAt: now)
    try store.applySync(issues: [issue(key: "DEMO-1", status: "In Progress")],
                        events: [], observedAt: now)

    let mirror = try store.loadMirror()
    #expect(Set(mirror.keys) == ["DEMO-1"])
}

@Test func eventsAccumulateAndAreNeverReplaced() throws {
    let store = try makeStore()
    let day1 = iso("2026-08-11T09:00:00Z")
    let day2 = iso("2026-08-12T09:00:00Z")

    let first = DomainEvent(issueKey: "DEMO-1", kind: .appeared, fromStatus: nil,
                            toStatus: "To Do", observedAt: day1, actorAccountId: "acc-me")
    let second = DomainEvent(issueKey: "DEMO-1", kind: .statusChanged, fromStatus: "To Do",
                             toStatus: "In Progress", observedAt: day2, actorAccountId: "acc-me")

    try store.applySync(issues: [], events: [first], observedAt: day1)
    try store.applySync(issues: [], events: [second], observedAt: day2)

    let events = try store.loadEvents()
    #expect(events.count == 2)
    #expect(events.map(\.kind) == [.appeared, .statusChanged], "시간순으로 돌려준다")
    #expect(events[1].fromStatus == "To Do")
}

@Test func syncRunRecordsSuccessAndFailure() throws {
    let store = try makeStore()
    let start = iso("2026-08-12T09:00:00Z")

    let ok = try store.beginSyncRun(at: start)
    try store.finishSyncRun(ok, at: start.addingTimeInterval(2), issueCount: 50, failure: nil)

    let failed = try store.beginSyncRun(at: start.addingTimeInterval(300))
    try store.finishSyncRun(failed, at: start.addingTimeInterval(302), issueCount: 0,
                            failure: "offline")

    #expect(try store.observationDayCount(now: start.addingTimeInterval(days(3))) == 4)
}

@Test func observationDayCountIsOneOnTheFirstDay() throws {
    let store = try makeStore()
    let start = iso("2026-08-12T09:00:00Z")
    let run = try store.beginSyncRun(at: start)
    try store.finishSyncRun(run, at: start, issueCount: 1, failure: nil)
    #expect(try store.observationDayCount(now: start.addingTimeInterval(hours(5))) == 1)
}

@Test func observationDayCountIsZeroBeforeAnySuccessfulSync() throws {
    let store = try makeStore()
    #expect(try store.observationDayCount(now: iso("2026-08-12T09:00:00Z")) == 0)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter Store`
Expected: FAIL — `cannot find 'ArcadeStore' in scope`

- [ ] **Step 3: `@Model` 정의**

```swift
import Foundation
import SwiftData

@Model
public final class IssueSnapshot {
    @Attribute(.unique) public var key: String
    public var summary: String
    public var statusName: String
    public var issueType: String
    public var priority: String?
    public var assigneeAccountId: String?
    public var assigneeName: String?
    public var dueDate: Date?
    public var jiraUpdatedAt: Date
    public var firstObservedAt: Date
    public var lastObservedAt: Date

    public init(
        key: String, summary: String, statusName: String, issueType: String,
        priority: String?, assigneeAccountId: String?, assigneeName: String?,
        dueDate: Date?, jiraUpdatedAt: Date, firstObservedAt: Date, lastObservedAt: Date
    ) {
        self.key = key
        self.summary = summary
        self.statusName = statusName
        self.issueType = issueType
        self.priority = priority
        self.assigneeAccountId = assigneeAccountId
        self.assigneeName = assigneeName
        self.dueDate = dueDate
        self.jiraUpdatedAt = jiraUpdatedAt
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
    }
}

/// append-only 이벤트 로그. 이 타입을 수정하거나 삭제하는 코드를 작성하지 않는다.
@Model
public final class IssueEventRecord {
    public var issueKey: String
    public var kindRaw: String
    public var fromStatus: String?
    public var toStatus: String?
    public var observedAt: Date
    public var actorAccountId: String?

    public init(
        issueKey: String, kindRaw: String, fromStatus: String?, toStatus: String?,
        observedAt: Date, actorAccountId: String?
    ) {
        self.issueKey = issueKey
        self.kindRaw = kindRaw
        self.fromStatus = fromStatus
        self.toStatus = toStatus
        self.observedAt = observedAt
        self.actorAccountId = actorAccountId
    }
}

@Model
public final class SyncRunRecord {
    public var startedAt: Date
    public var finishedAt: Date?
    public var observedIssueCount: Int
    public var failureMessage: String?

    public init(startedAt: Date) {
        self.startedAt = startedAt
        self.observedIssueCount = 0
    }
}
```

- [ ] **Step 4: `ArcadeStore` 구현**

```swift
import Foundation
import SwiftData

public enum ArcadeStoreError: Error, Equatable {
    /// `beginSyncRun`이 돌려준 식별자로 레코드를 되찾지 못했다.
    /// 정상 흐름에서는 발생하지 않지만, 조용히 넘기면 동기화 이력이 영구히 미완료로 남는다.
    case syncRunNotFound
}

/// SwiftData 모델과 순수 값 타입 사이의 유일한 경계.
/// 규칙 엔진은 이 타입 너머의 @Model을 절대 보지 않는다.
@MainActor
public final class ArcadeStore {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    public init(container: ModelContainer) {
        self.container = container
    }

    public static func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: IssueSnapshot.self, IssueEventRecord.self, SyncRunRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    public static func makePersistentContainer() throws -> ModelContainer {
        try ModelContainer(for: IssueSnapshot.self, IssueEventRecord.self, SyncRunRecord.self)
    }

    // MARK: - 미러

    public func loadMirror() throws -> [String: ObservedIssue] {
        let rows = try context.fetch(FetchDescriptor<IssueSnapshot>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.asObservedIssue) })
    }

    /// 미러를 새 조회 결과로 맞추고 이벤트를 덧붙인다.
    /// issues가 비어 있으면 미러를 건드리지 않는다(이벤트만 기록하는 호출을 허용하기 위함).
    public func applySync(issues: [ObservedIssue], events: [DomainEvent], observedAt: Date) throws {
        if !issues.isEmpty {
            let existing = try context.fetch(FetchDescriptor<IssueSnapshot>())
            var byKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })

            for issue in issues {
                if let row = byKey.removeValue(forKey: issue.key) {
                    row.apply(issue, observedAt: observedAt)
                } else {
                    context.insert(IssueSnapshot(issue, observedAt: observedAt))
                }
            }
            for orphan in byKey.values {
                context.delete(orphan)   // 미러만 정리한다. 이벤트 로그는 그대로 둔다.
            }
        }

        for event in events {
            context.insert(IssueEventRecord(
                issueKey: event.issueKey, kindRaw: event.kind.rawValue,
                fromStatus: event.fromStatus, toStatus: event.toStatus,
                observedAt: event.observedAt, actorAccountId: event.actorAccountId
            ))
        }

        try context.save()
    }

    // MARK: - 이벤트

    public func loadEvents() throws -> [DomainEvent] {
        let descriptor = FetchDescriptor<IssueEventRecord>(
            sortBy: [SortDescriptor(\.observedAt, order: .forward)]
        )
        return try context.fetch(descriptor).compactMap { record in
            guard let kind = EventKind(rawValue: record.kindRaw) else { return nil }
            return DomainEvent(
                issueKey: record.issueKey, kind: kind,
                fromStatus: record.fromStatus, toStatus: record.toStatus,
                observedAt: record.observedAt, actorAccountId: record.actorAccountId
            )
        }
    }

    // MARK: - 동기화 이력

    public func beginSyncRun(at start: Date) throws -> PersistentIdentifier {
        let record = SyncRunRecord(startedAt: start)
        context.insert(record)
        try context.save()
        return record.persistentModelID
    }

    public func finishSyncRun(
        _ id: PersistentIdentifier, at end: Date, issueCount: Int, failure: String?
    ) throws {
        // 조용히 return하면 이 SyncRunRecord가 finishedAt == nil로 영원히 남고,
        // observationDayCount의 #Predicate가 이를 영구 배제한다. 하필 가장 이른 성공
        // 동기화에서 발생하면 "관측 N일차"가 계속 0을 표시한다 — 추적이 거의 불가능한 실패다.
        guard let record = context.model(for: id) as? SyncRunRecord else {
            throw ArcadeStoreError.syncRunNotFound
        }
        record.finishedAt = end
        record.observedIssueCount = issueCount
        record.failureMessage = failure
        try context.save()
    }

    /// 첫 성공 동기화 이후 며칠째인지. 성공한 동기화가 없으면 0.
    public func observationDayCount(now: Date, calendar: Calendar = .current) throws -> Int {
        var descriptor = FetchDescriptor<SyncRunRecord>(
            predicate: #Predicate { $0.failureMessage == nil && $0.finishedAt != nil },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
        descriptor.fetchLimit = 1
        guard let first = try context.fetch(descriptor).first else { return 0 }

        let start = calendar.startOfDay(for: first.startedAt)
        let today = calendar.startOfDay(for: now)
        let elapsed = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        return max(1, elapsed + 1)
    }
}

// MARK: - 변환

private extension IssueSnapshot {
    var asObservedIssue: ObservedIssue {
        ObservedIssue(
            key: key, summary: summary, statusName: statusName, issueType: issueType,
            priority: priority, assigneeAccountId: assigneeAccountId, assigneeName: assigneeName,
            dueDate: dueDate, jiraUpdatedAt: jiraUpdatedAt
        )
    }

    convenience init(_ issue: ObservedIssue, observedAt: Date) {
        self.init(
            key: issue.key, summary: issue.summary, statusName: issue.statusName,
            issueType: issue.issueType, priority: issue.priority,
            assigneeAccountId: issue.assigneeAccountId, assigneeName: issue.assigneeName,
            dueDate: issue.dueDate, jiraUpdatedAt: issue.jiraUpdatedAt,
            firstObservedAt: observedAt, lastObservedAt: observedAt
        )
    }

    func apply(_ issue: ObservedIssue, observedAt: Date) {
        summary = issue.summary
        statusName = issue.statusName
        issueType = issue.issueType
        priority = issue.priority
        assigneeAccountId = issue.assigneeAccountId
        assigneeName = issue.assigneeName
        dueDate = issue.dueDate
        jiraUpdatedAt = issue.jiraUpdatedAt
        lastObservedAt = observedAt
    }
}
```

- [ ] **Step 5: 테스트에 `@MainActor` 부여**

`ArcadeStore`가 `@MainActor`이므로 `StoreTests.swift` 최상단의 각 `@Test` 함수에 `@MainActor`를 붙이고, `makeStore()` 헬퍼에도 붙인다. 예:

```swift
@MainActor
private func makeStore() throws -> ArcadeStore {
    ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
}

@MainActor
@Test func mirrorRoundTripsThroughSwiftData() throws { … }
```

- [ ] **Step 6: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter Store`
Expected: PASS (7 tests)

- [ ] **Step 7: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Store/ \
        Packages/Jirarcade/Tests/ArcadeCoreTests/StoreTests.swift
git commit -m "feat: SwiftData 미러와 append-only 이벤트 로그 저장소"
```

---

### Task 17: SyncEngine — 페치·diff·저장·집계 조합

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Sync/SyncEngine.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/SyncEngineTests.swift`

**Interfaces:**
- Consumes: `JiraClient`(Task 14), `ArcadeStore`(Task 16), `DiffEngine`(Task 11), `ScoreEngine`(Task 10), `ObservedIssue`(Task 15)
- Produces: `protocol IssueSource` (`fetchAssignedIssues(jql:now:) async throws -> [ObservedIssue]`), `JiraIssueSource`, `SyncOutcome` (`newEvents`, `summary`), `SyncEngine(source:store:rules:workflow:calendar:)`, `sync(jql:now:) async throws -> SyncOutcome`

> **진단용 디코딩 실패 개수는 이 계획에서 전달하지 않는다.** `IssuePage.failures`(Task 13)가 실패한 티켓을 기록하지만, `IssueSource.fetchAssignedIssues`가 `[ObservedIssue]`만 반환하므로 그 정보가 `SyncEngine`까지 오지 못한다. 스펙 §8.4는 디코딩 실패를 "표시하지 않고 진단에만" 노출하라고 하는데, 진단 화면은 계획 2(UI)의 몫이다. 그때 `IssueSource`가 `(issues, failureCount)`를 돌려주도록 넓히고 `SyncOutcome`에 필드를 추가한다. 지금 넣으면 소비자 없는 값이 된다.

- [ ] **Step 1: 실패하는 테스트 작성**

`JiraClient`를 직접 쓰지 않고 `IssueSource` 프로토콜을 두면, SyncEngine 테스트가 HTTP 스텁 없이 돈다.

```swift
import Testing
import Foundation
@testable import ArcadeCore

private var utc: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

/// 호출 순서대로 미리 정한 결과를 돌려주는 테스트용 소스.
private final class ScriptedSource: IssueSource, @unchecked Sendable {
    private var pages: [[ObservedIssue]]
    var error: (any Error)?
    private(set) var callCount = 0

    init(_ pages: [[ObservedIssue]]) { self.pages = pages }

    func fetchAssignedIssues(jql: String, now: Date) async throws -> [ObservedIssue] {
        callCount += 1
        if let error { throw error }
        return pages.isEmpty ? [] : pages.removeFirst()
    }
}

@MainActor
private func makeEngine(_ source: ScriptedSource) throws -> (SyncEngine, ArcadeStore) {
    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let engine = SyncEngine(source: source, store: store, rules: .default,
                            workflow: demoWorkflow, calendar: utc)
    return (engine, store)
}

@MainActor
@Test func firstSyncRecordsAppearedEventsForEveryIssue() async throws {
    let source = ScriptedSource([[issue(key: "DEMO-1", status: "To Do"),
                                  issue(key: "DEMO-2", status: "In Progress")]])
    let (engine, store) = try makeEngine(source)

    let outcome = try await engine.sync(jql: "assignee = currentUser()",
                                        now: iso("2026-08-12T09:00:00Z"))

    #expect(outcome.newEvents.count == 2)
    #expect(outcome.newEvents.allSatisfy { $0.kind == .appeared })
    #expect(try store.loadMirror().count == 2)
}

@MainActor
@Test func secondSyncOnlyRecordsWhatChanged() async throws {
    let day1 = iso("2026-08-11T09:00:00Z")
    let day2 = iso("2026-08-12T09:00:00Z")
    let source = ScriptedSource([
        [issue(key: "DEMO-1", status: "To Do", updated: day1)],
        [issue(key: "DEMO-1", status: "In Progress", updated: day2)],
    ])
    let (engine, _) = try makeEngine(source)

    _ = try await engine.sync(jql: "q", now: day1)
    let second = try await engine.sync(jql: "q", now: day2)

    #expect(second.newEvents.map(\.kind) == [.statusChanged])
    #expect(second.newEvents[0].toStatus == "In Progress")
}

@MainActor
@Test func repeatedSyncWithNoChangesAddsNoEvents() async throws {
    let day = iso("2026-08-12T09:00:00Z")
    let same = issue(key: "DEMO-1", status: "In Progress", updated: day)
    let source = ScriptedSource([[same], [same]])
    let (engine, store) = try makeEngine(source)

    _ = try await engine.sync(jql: "q", now: day)
    let second = try await engine.sync(jql: "q", now: day)

    #expect(second.newEvents.isEmpty)
    #expect(try store.loadEvents().count == 1, "첫 동기화의 appeared 1건만 남는다")
}

@MainActor
@Test func summaryReflectsTheWholeEventLog() async throws {
    let day1 = iso("2026-08-11T09:00:00Z")
    let day2 = iso("2026-08-12T09:00:00Z")
    let source = ScriptedSource([
        [issue(key: "DEMO-1", status: "To Do", updated: day1)],
        [issue(key: "DEMO-1", status: "In Progress", updated: day2)],
    ])
    let (engine, _) = try makeEngine(source)

    _ = try await engine.sync(jql: "q", now: day1)
    let second = try await engine.sync(jql: "q", now: day2)

    #expect(second.summary.totalXP > 0)
    #expect(second.summary.level >= 1)
}

@MainActor
@Test func failedSyncLeavesTheMirrorIntactAndRethrows() async throws {
    let day = iso("2026-08-12T09:00:00Z")
    let source = ScriptedSource([[issue(key: "DEMO-1", status: "In Progress", updated: day)]])
    let (engine, store) = try makeEngine(source)
    _ = try await engine.sync(jql: "q", now: day)

    source.error = JiraError.offline
    await #expect(throws: JiraError.offline) {
        _ = try await engine.sync(jql: "q", now: day.addingTimeInterval(300))
    }

    #expect(try store.loadMirror().count == 1, "실패해도 마지막 미러는 남는다")
}
```

`JiraError`를 쓰려면 테스트 상단에 `import JiraKit`을 추가한다.

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter SyncEngine`
Expected: FAIL — `cannot find 'SyncEngine' in scope`

- [ ] **Step 3: 구현**

```swift
import Foundation
import JiraKit

/// 티켓을 가져오는 방법을 추상화한다. 덕분에 SyncEngine 테스트가 HTTP 없이 돈다.
public protocol IssueSource: Sendable {
    func fetchAssignedIssues(jql: String, now: Date) async throws -> [ObservedIssue]
}

/// 실제 Jira를 쓰는 구현. 페이지네이션을 모두 소진해 한 번에 돌려준다.
public struct JiraIssueSource: IssueSource {
    private let client: JiraClient
    private let fields = [
        "summary", "status", "issuetype", "priority", "assignee", "duedate", "updated",
    ]

    public init(client: JiraClient) {
        self.client = client
    }

    public func fetchAssignedIssues(jql: String, now: Date) async throws -> [ObservedIssue] {
        var collected: [ObservedIssue] = []
        var token: String?

        repeat {
            let page = try await client.searchIssues(
                jql: jql, fields: fields, maxResults: 100, pageToken: token
            )
            collected.append(contentsOf: page.issues.map(ObservedIssue.init))
            token = page.nextPageToken
        } while token != nil

        return collected
    }
}

public struct SyncOutcome: Sendable {
    public let newEvents: [DomainEvent]
    public let summary: PlayerSummary
}

/// 페치 → diff → 저장 → 재집계를 한 번의 호출로 묶는다.
@MainActor
public final class SyncEngine {
    private let source: any IssueSource
    private let store: ArcadeStore
    private let diffEngine = DiffEngine()
    private let scoreEngine: ScoreEngine

    public init(
        source: any IssueSource, store: ArcadeStore,
        rules: RuleSet, workflow: WorkflowMap, calendar: Calendar
    ) {
        self.source = source
        self.store = store
        self.scoreEngine = ScoreEngine(rules: rules, workflow: workflow, calendar: calendar)
    }

    public func sync(jql: String, now: Date) async throws -> SyncOutcome {
        let runID = try store.beginSyncRun(at: now)

        let fetched: [ObservedIssue]
        do {
            fetched = try await source.fetchAssignedIssues(jql: jql, now: now)
        } catch {
            try store.finishSyncRun(runID, at: now, issueCount: 0,
                                    failure: String(describing: error))
            throw error
        }

        let previous = try store.loadMirror()
        let events = diffEngine.diff(previous: previous, current: fetched, observedAt: now)
        try store.applySync(issues: fetched, events: events, observedAt: now)
        try store.finishSyncRun(runID, at: now, issueCount: fetched.count, failure: nil)

        let allEvents = try store.loadEvents()
        let mirror = try store.loadMirror()
        let (_, summary) = scoreEngine.recompute(events: allEvents, issues: mirror, now: now)

        return SyncOutcome(newEvents: events, summary: summary)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter SyncEngine`
Expected: PASS (5 tests)

- [ ] **Step 5: 전체 테스트 실행**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS (누적 90건 이상, 실패 0)

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Sync/SyncEngine.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/SyncEngineTests.swift
git commit -m "feat: SyncEngine으로 페치·diff·저장·재집계 연결"
```

---

### Task 18: 팔레트 대비 검증 — 테마 토큰의 회귀 테스트

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Domain/PaletteTokens.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/ContrastTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces: `struct RGB(hex:)`, `relativeLuminance`, `contrastRatio(_:_:) -> Double`, `enum PaletteTokens` (`darkHex`·`lightHex` 딕셔너리)

테마 색은 `ArcadeUI`(계획 2)에서 `Color`로 쓰이지만, **hex 값과 대비 규칙은 UI 없이 검증할 수 있으므로 여기서 고정한다.** 계획 2의 `ArcadeTheme`은 이 딕셔너리를 읽어 `Color`를 만든다.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import Testing
@testable import ArcadeCore

@Test func knownContrastValuesAreComputedCorrectly() {
    let white = RGB(hex: "#FFFFFF")
    let black = RGB(hex: "#000000")
    #expect(abs(contrastRatio(white, black) - 21.0) < 0.05)
    #expect(abs(contrastRatio(white, white) - 1.0) < 0.001)
}

@Test func bothPalettesDefineTheSameTokenNames() {
    #expect(Set(PaletteTokens.darkHex.keys) == Set(PaletteTokens.lightHex.keys))
}

@Test(arguments: ["inkPrimary", "inkSecondary", "inkTertiary"])
func darkTextTokensMeetAA(token: String) {
    let ratio = PaletteTokens.contrastAgainstSurface(token: token, in: .dark)
    #expect(ratio >= 4.5, "\(token) 다크 대비 \(ratio)")
}

@Test(arguments: ["inkPrimary", "inkSecondary", "inkTertiary"])
func lightTextTokensMeetAA(token: String) {
    let ratio = PaletteTokens.contrastAgainstSurface(token: token, in: .light)
    #expect(ratio >= 4.5, "\(token) 라이트 대비 \(ratio)")
}

@Test(arguments: ["accent", "boss", "danger", "good"])
func darkAccentTokensMeetGraphicMinimum(token: String) {
    #expect(PaletteTokens.contrastAgainstSurface(token: token, in: .dark) >= 3.0)
}

@Test(arguments: ["accent", "boss", "danger", "good"])
func lightAccentTokensMeetGraphicMinimum(token: String) {
    #expect(PaletteTokens.contrastAgainstSurface(token: token, in: .light) >= 3.0)
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Packages/Jirarcade && swift test --filter Contrast`
Expected: FAIL — `cannot find 'RGB' in scope`

- [ ] **Step 3: 구현**

```swift
import Foundation

public struct RGB: Sendable, Equatable {
    public let red: Double, green: Double, blue: Double

    public init(hex: String) {
        var text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        let value = UInt32(text, radix: 16) ?? 0
        red   = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue  = Double(value & 0xFF) / 255
    }

    /// WCAG 2.1 상대 휘도.
    public var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}

public func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
    let first = a.relativeLuminance, second = b.relativeLuminance
    let lighter = max(first, second), darker = min(first, second)
    return (lighter + 0.05) / (darker + 0.05)
}

/// 두 테마의 색 토큰. ArcadeUI가 이 값을 읽어 Color를 만든다.
/// 대비 기준을 만족하지 못하는 값은 이 파일에서 고치고 테스트로 확인한다.
public enum PaletteTokens {
    public enum Appearance: Sendable { case dark, light }

    public static let darkHex: [String: String] = [
        "surfaceBase":   "#0A0B10",
        "surfaceRaised": "#13151F",
        "line":          "#262A3A",
        "inkPrimary":    "#E8E9F1",
        "inkSecondary":  "#878CA3",
        "inkTertiary":   "#7A7F94",
        "accent":        "#FFB43C",
        "boss":          "#FF3D8A",
        "danger":        "#FF6B5E",
        "good":          "#6EE87A",
    ]

    public static let lightHex: [String: String] = [
        "surfaceBase":   "#E9E9E4",
        "surfaceRaised": "#FFFFFF",
        "line":          "#C6C6BE",
        "inkPrimary":    "#16171C",
        "inkSecondary":  "#55575F",
        "inkTertiary":   "#63655D",
        "accent":        "#8F4E00",
        "boss":          "#A8115C",
        "danger":        "#A81F14",
        "good":          "#1A6B2C",
    ]

    public static func hex(_ token: String, in appearance: Appearance) -> String {
        let table = appearance == .dark ? darkHex : lightHex
        guard let value = table[token] else {
            fatalError("정의되지 않은 색 토큰: \(token)")
        }
        return value
    }

    public static func contrastAgainstSurface(token: String, in appearance: Appearance) -> Double {
        contrastRatio(
            RGB(hex: hex(token, in: appearance)),
            RGB(hex: hex("surfaceBase", in: appearance))
        )
    }
}
```

> 스펙 §6의 표에서 `inkTertiary`(다크 `#5B6076`, 라이트 `#8A8B84`)와 라이트 `boss`·`danger`·`good`은 계산상 기준에 미달하거나 경계선이므로 위 값으로 조정했다. 다른 토큰은 스펙 그대로다.

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Packages/Jirarcade && swift test --filter Contrast`
Expected: PASS (16 tests — 파라미터화 14건 포함)

일부 토큰이 실패하면 `PaletteTokens`의 해당 hex를 조정한다(다크는 밝게, 라이트는 어둡게). 테스트를 완화하지 않는다.

- [ ] **Step 5: 스펙의 팔레트 표를 확정값으로 갱신**

`docs/superpowers/specs/2026-08-12-jirarcade-design.md` §6의 표에서 조정된 토큰의 hex를 위 값으로 고치고, "표의 hex 값은 초기 후보다" 문단을 "대비 테스트로 확정된 값이다"로 바꾼다.

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Domain/PaletteTokens.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/ContrastTests.swift \
        docs/superpowers/specs/2026-08-12-jirarcade-design.md
git commit -m "feat: 테마 팔레트 토큰과 WCAG 대비 회귀 테스트"
```

---

### Task 19: 통합 확인 — 실제 응답 형태로 전 구간 관통

**Files:**
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/Fixtures/sample-issues.json`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/EndToEndTests.swift`
- Modify: `Packages/Jirarcade/Package.swift`

**Interfaces:**
- Consumes: 모든 이전 태스크
- Produces: 없음 (검증 전용)

- [ ] **Step 1: fixture 작성**

실 업무 내용을 커밋하지 않는다. 상태명·워크플로 같은 **구조는 실제 그대로**, 요약문은 일반화한다. `Tests/ArcadeCoreTests/Fixtures/sample-issues.json`:

```json
{
  "issues": [
    { "key": "DEMO-9613", "fields": {
        "summary": "[통합/태블릿] 화면 A에 버튼 추가",
        "status": { "name": "In Progress" }, "issuetype": { "name": "개선" },
        "priority": { "name": "Medium" },
        "assignee": { "accountId": "acc-me", "displayName": "bahn" },
        "updated": "2026-08-12T15:04:05.000+0900" } },
    { "key": "DEMO-9610", "fields": {
        "summary": "[통합/태블릿] 완료 화면 추가",
        "status": { "name": "In Review" }, "issuetype": { "name": "개선" },
        "priority": { "name": "Medium" },
        "assignee": { "accountId": "acc-me", "displayName": "bahn" },
        "duedate": "2026-08-12",
        "updated": "2026-08-12T11:00:00.000+0900" } },
    { "key": "DEMO-9074", "fields": {
        "summary": "[통합] 통계 기반 인사이트 제공",
        "status": { "name": "To Do" }, "issuetype": { "name": "새 기능" },
        "priority": { "name": "Medium" },
        "assignee": { "accountId": "acc-me", "displayName": "bahn" },
        "updated": "2026-08-07T09:00:00.000+0900" } },
    { "key": "DEMO-8984", "fields": {
        "summary": "[통합] 서버 성능 및 메모리 누수 개선",
        "status": { "name": "Verifying" }, "issuetype": { "name": "개선" },
        "priority": { "name": "Medium" },
        "assignee": { "accountId": "acc-me", "displayName": "bahn" },
        "updated": "2026-08-07T09:00:00.000+0900" } },
    { "key": "DEMO-BROKEN", "fields": {
        "summary": "상태 필드가 없어 파싱에 실패해야 하는 행" } }
  ]
}
```

- [ ] **Step 2: `Package.swift`에 리소스 선언 추가**

`ArcadeCoreTests` 타깃을 다음으로 교체한다.

```swift
.testTarget(
    name: "ArcadeCoreTests",
    dependencies: ["ArcadeCore"],
    resources: [.process("Fixtures")]
),
```

- [ ] **Step 3: 실패하는 테스트 작성**

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

private func loadFixture() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "sample-issues", withExtension: "json"))
    return try Data(contentsOf: url)
}

@Test func fixtureDecodesFourIssuesAndOneFailure() throws {
    let page = try JiraSearchResponse.decode(try loadFixture())
    #expect(page.issues.count == 4)
    #expect(page.failures.count == 1)
}

@MainActor
@Test func fullPipelineProducesEventsAndScore() async throws {
    let page = try JiraSearchResponse.decode(try loadFixture())
    let issues = page.issues.map(ObservedIssue.init)

    let store = ArcadeStore(container: try ArcadeStore.makeInMemoryContainer())
    let source = FixedSource(issues: issues)
    let engine = SyncEngine(source: source, store: store, rules: .default,
                            workflow: demoWorkflow, calendar: utc)

    let outcome = try await engine.sync(jql: "assignee = currentUser()",
                                        now: iso("2026-08-12T09:00:00Z"))

    #expect(outcome.newEvents.count == 4)
    #expect(outcome.summary.level >= 1)
}

@Test func hygieneOnFixtureReflectsRealStatusNames() throws {
    let page = try JiraSearchResponse.decode(try loadFixture())
    let issues = page.issues.map(ObservedIssue.init)
    let report = HygieneCalculator(rules: .default, workflow: demoWorkflow)
        .evaluate(issues, now: iso("2026-08-12T09:00:00Z"))

    #expect(report.wipCount == 1, "active는 DEMO-9613 한 건이다")
    #expect(report.wipPenalty == 0, "WIP 한도 이하이므로 감점 없음")
}

private struct FixedSource: IssueSource {
    let issues: [ObservedIssue]
    func fetchAssignedIssues(jql: String, now: Date) async throws -> [ObservedIssue] { issues }
}
```

- [ ] **Step 4: 테스트 실행**

Run: `cd Packages/Jirarcade && swift test --filter EndToEnd`
Expected: PASS (3 tests)

- [ ] **Step 5: 전체 테스트와 경고 확인**

Run: `cd Packages/Jirarcade && swift build 2>&1 | grep -i warning; swift test`
Expected: 경고 없음, 전체 PASS

- [ ] **Step 6: 커밋**

```bash
git add Packages/Jirarcade/
git commit -m "test: 실제 응답 형태 fixture로 전 구간 통합 검증"
```

---

## 완료 조건

계획 1이 끝났다고 말할 수 있는 조건:

```
□ swift build 경고 없이 성공
□ swift test 전부 통과 (약 95건)
□ ArcadeCore의 규칙 테스트가 SwiftData·네트워크 없이 동작
□ JiraKit이 ArcadeCore를 import하지 않음 (grep으로 확인)
□ 규칙 상수가 RuleSet 밖에 하드코딩되어 있지 않음
□ ScoreEngine 재집계가 멱등
□ 두 팔레트가 대비 기준 통과
```

마지막 두 항목은 다음 명령으로 확인한다:

```bash
cd Packages/Jirarcade
grep -rn "import ArcadeCore" Sources/JiraKit/ && echo "의존 방향 위반" || echo "의존 방향 정상"
swift test --filter "ScoreEngine|Contrast"
```

## 다음 단계

계획 2(`ArcadeUI` + `QuestBoard` + 앱 타깃)는 이 계획이 끝난 뒤 별도로 작성한다. 계획 2가 소비할 인터페이스는 다음과 같이 고정된다:

- `SyncEngine.sync(jql:now:) async throws -> SyncOutcome`
- `ArcadeStore.loadMirror()`, `loadEvents()`, `observationDayCount(now:)`
- `ScoreEngine.recompute(events:issues:now:)`
- `HygieneCalculator.evaluate(_:now:) -> HygieneReport`
- `StagnationClassifier.classify(statusEnteredAt:jiraUpdatedAt:now:)`, `isApproximate(statusEnteredAt:)`
- `LevelCurve.progress(forTotalXP:)`
- `PaletteTokens.hex(_:in:)`
- `JiraClient.transitions(issueKey:)`, `performTransition(issueKey:transitionId:)`

계획 2에서 반드시 처리할 미결 사항 하나 — 스펙 §5.4의 체크인 조건은 "상태 전이 **또는 상세 시트 열람**"인데, 이 계획의 `ScoreEngine.checkInDays`는 XP가 붙은 이벤트가 있는 날만 센다. 열람은 Jira에 흔적을 남기지 않으므로, UI가 로컬 열람 이벤트를 만들어 `ArcadeStore`에 기록하고 `checkInDays`가 그것도 세도록 확장해야 한다.
