# 궤도 뷰 (계획 2b-4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 퀘스트 보드 안에서 레인과 궤도를 오갈 수 있게 하고, 궤도에서는 상태 하나가 태양이 되어 그 상태의 티켓이 정체일만큼 떨어진 궤도에 놓이게 한다. 줌아웃하면 같은 `Stage`의 태양들이 한 점으로 수렴해 보드 레인과 1:1이 되고, 줌인하면 조직의 실제 상태로 갈라진다.

**Architecture:** 좌표 계산은 전부 `ArcadeCore`의 순수 함수다 — 애니메이션이 있는 화면에서는 눈으로 하는 검증이 약해지므로, "45일 티켓은 반경 1.0에 있다"를 `swift test`가 확인해야 한다. 뷰는 논리 좌표를 pt로 옮기는 곱셈만 한다(`BoardMetrics`가 이미 같은 역할을 한다). 행성은 SwiftUI 뷰로 두어 `matchedGeometryEffect`로 카드 ↔ 행성 전환을 얻는다. 상시 애니메이션이 없으므로 이 규모에서 성능이 선택을 강제하지 않는다.

**Tech Stack:** Swift 6.2 / SwiftUI / Swift Testing

**Spec:** `docs/superpowers/specs/2026-08-24-orbit-view-design.md`
**선행 스펙:** `docs/superpowers/specs/2026-08-12-jirarcade-design.md` (v0.1) · `docs/superpowers/specs/2026-08-21-quest-board-design.md` (퀘스트 보드 · 축 · 레인)

## Global Constraints

- 스펙 원본은 위 세 문서다. 충돌 시 궤도 뷰 스펙(2026-08-24)이 우선한다.
- 모듈 의존 방향은 단방향이다: `ArcadeUI → ArcadeApp → ArcadeCore → JiraKit`. 역방향 import 금지.
- **`ArcadeApp`은 SwiftUI를 import하지 않는다.** `ModuleBoundaryTests.arcadeAppNeverImportsSwiftUI`가 강제한다.
- **`ArcadeUI`의 뷰 코드에 색 리터럴을 두지 않는다.** 모든 색은 `@Environment(\.arcadeTheme)`에서 온다. `ModuleBoundaryTests.viewsUseThemeTokensRatherThanColorLiterals`가 hex·`Color.red`·`.primary`·`Color(red:)`까지 잡는다.
- **뷰는 `Date()`·`Calendar.current`·`RuleSet.default`를 직접 부르지 않는다.** 현재 `Sources/ArcadeUI/` 아래 이 셋의 출현 횟수는 **0이며 그대로 유지한다.**
- **`ArcadeCore`는 화면을 모른다.** pt도 픽셀도 줌 배율도 제스처도 모른다. 논리 좌표(1.0 = 궤도 최대 반경)만 돌려준다.
- **새 팔레트 토큰을 만들지 않는다.** `TicketCardView`가 이미 등급을 기존 토큰에 대응시켰다 — `fresh`→`theme.line`, `stale`→`theme.accent`, `boss`/`raid`→`theme.boss`이며 raid는 색이 아니라 **채움**으로 가른다. 궤도도 같은 매핑을 쓴다. 토큰을 더하면 `ContrastTests`를 통과시켜야 하고 두 테마에서 다시 검증해야 한다.
- **채점·동기화·저장소를 건드리지 않는다.** 이 계획은 읽기 전용 화면 하나를 더한다. `XpAwarder`·`HygieneCalculator`·`ScoreEngine`·`SyncEngine`·`ArcadeStore`에 변경이 없어야 한다.
- **`Date.now`·`Math.random`·`Int.random`·`String.hashValue`를 좌표 계산에 쓰지 않는다.** 좌표는 같은 입력에 언제나 같은 출력을 내야 한다(자세한 이유는 Task 1).
- 조직 특정 정보를 코드·테스트에 넣지 않는다. 테스트는 `example.atlassian.net`, `DEMO-`를 쓴다. `ModuleBoundaryTests.onlyTheExampleJiraSiteAppearsAnywhere`가 강제한다.
- 테스트는 Swift Testing(`@Test` / `#expect`)을 쓴다.
- 정렬은 결정적이어야 한다 — 동률 타이브레이크를 명시한다.
- 각 태스크는 `swift test` 통과 후 커밋으로 끝난다. 테스트는 `Packages/Jirarcade`에서 돈다.

## File Structure

```
Packages/Jirarcade/
├── Sources/
│   ├── ArcadeCore/Board/
│   │   ├── OrbitGeometry.swift          ← 신규. 결정론적 해시 · 각도 · 우선순위 크기
│   │   ├── OrbitPacker.swift            ← 신규. 원형 겹침 해소 (LanePacker의 극좌표판)
│   │   └── OrbitLayout.swift            ← 신규. 도메인 타입 + 스냅샷 조립
│   ├── ArcadeApp/
│   │   └── AppModel.swift               ← 수정. orbitSnapshot(zoomProgress:) 추가
│   └── ArcadeUI/QuestBoard/
│       ├── OrbitMetrics.swift           ← 신규. 논리 좌표 → pt (BoardMetrics와 같은 역할)
│       ├── PlanetView.swift             ← 신규. 행성 한 개
│       ├── OrbitView.swift              ← 신규. 태양 · 궤도선 · 팬 · 줌
│       ├── BoardViewMode.swift          ← 신규. 레인/궤도 토글
│       └── QuestBoardView.swift         ← 수정. 토글 배선과 모드 분기
└── Tests/
    ├── ArcadeCoreTests/OrbitGeometryTests.swift   ← 신규
    ├── ArcadeCoreTests/OrbitPackerTests.swift     ← 신규
    ├── ArcadeCoreTests/OrbitLayoutTests.swift     ← 신규
    └── ArcadeAppTests/AppModelTests.swift         ← 수정. 궤도 스냅샷과 낙관적 사본
```

파일을 셋으로 가른 이유: `OrbitGeometry`는 티켓을 모르는 순수 수학이고, `OrbitPacker`는 좌표만 아는 배치 알고리즘이며, `OrbitLayout`은 도메인을 좌표로 옮기는 조립이다. 한 파일에 넣으면 해시 함수를 고치려고 티켓 타입을 읽어야 한다. `ArcadeCore/Board/`에 이미 `BoardAxis`·`LanePacker`·`BoardLayout`이 같은 방식으로 갈려 있다.

**뷰가 `OrbitLayout.snapshot`을 직접 부르지 않는다.** 그 함수는 `now`와 `calendar`를 받는데, `Sources/ArcadeUI/` 아래 `Date()`·`Calendar.current`의 출현 횟수는 현재 **0이고 그것이 규칙이다**(Global Constraints). `AppModel.boardSnapshot(minimumSpacing:)`이 `clock()`과 `calendar`를 주입하는 이유가 정확히 그것이므로, 궤도도 `orbitSnapshot(zoomProgress:)`로 같은 경로를 쓴다(Task 4).

그 경로를 쓰면 **대기 중인 전이가 궤도에도 즉시 반영된다.** `boardSnapshot`은 `optimisticIssues`를 읽어 아직 Jira에 보내지 않은 전이를 미러 위에 겹치는데, 궤도가 `issues`를 직접 읽으면 카드에서 상태를 옮겨도 행성이 5초 동안 옛 태양에 남아 있게 된다.

---

### Task 1: `OrbitGeometry` — 결정론적 해시와 각도

행성이 원의 어느 방향에 놓일지를 티켓 키에서 계산한다. 화면도 티켓도 모르는 순수 수학이라 가장 먼저 만든다.

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Board/OrbitGeometry.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/OrbitGeometryTests.swift`

**Interfaces:**
- Consumes: 없음 (`Foundation`만)
- Produces:
  - `public struct OrbitPoint: Sendable, Equatable { public let x: Double; public let y: Double; public init(x: Double, y: Double) }`
  - `public enum OrbitGeometry`
    - `public static func stableHash(_ text: String) -> UInt64`
    - `public static func angle(forKey key: String) -> Double` — `[0, 2π)`
    - `public static func angularDistance(_ a: Double, _ b: Double) -> Double` — `[0, π]`
    - `public static func point(center: OrbitPoint, radius: Double, angle: Double) -> OrbitPoint`
    - `public static func sizeFactor(forPriority priority: String?) -> Double`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Packages/Jirarcade/Tests/ArcadeCoreTests/OrbitGeometryTests.swift`:

```swift
import Testing
import Foundation
@testable import ArcadeCore

/// 해시값을 리터럴로 굳혀 둔다. 이것이 `String.hashValue`로 되돌아가는 것을 막는
/// 유일한 방어다 — Swift의 기본 해시는 프로세스마다 무작위 시드를 쓰므로 앱을 다시
/// 열 때마다 모든 행성이 다른 자리로 간다. 화면은 매 실행 정상으로 보이고, 테스트는
/// 한 프로세스 안에서 도는 탓에 그 사실을 잡지 못한다.
@Test func hashesKeysToKnownValues() {
    #expect(OrbitGeometry.stableHash("DEMO-1") == 2_116_399_489_896_580_304)
    #expect(OrbitGeometry.stableHash("DEMO-2") == 2_116_402_788_431_464_937)
    #expect(OrbitGeometry.stableHash("DEMO-3") == 2_116_401_688_919_836_726)
}

@Test func mapsKeysToKnownAngles() {
    #expect(abs(OrbitGeometry.angle(forKey: "DEMO-1") - 3.646157566) < 1e-6)
    #expect(abs(OrbitGeometry.angle(forKey: "DEMO-2") - 2.921285327) < 1e-6)
}

@Test func keepsAnglesInsideOneTurn() {
    for index in 1...200 {
        let angle = OrbitGeometry.angle(forKey: "DEMO-\(index)")
        #expect(angle >= 0)
        #expect(angle < 2 * .pi)
    }
}

/// 각거리는 원을 도는 거리다. 0.1과 6.2는 수직선에서 6.1 떨어져 있지만
/// 원에서는 0.18쯤이다 — 이걸 틀리면 12시 근처 행성들이 겹친다.
@Test func measuresDistanceAroundTheCircle() {
    let distance = OrbitGeometry.angularDistance(0.1, 6.2)
    #expect(abs(distance - (2 * .pi - 6.1)) < 1e-9)
    #expect(distance <= .pi)
}

@Test func treatsAngularDistanceAsSymmetric() {
    let forward = OrbitGeometry.angularDistance(1.0, 4.0)
    let backward = OrbitGeometry.angularDistance(4.0, 1.0)
    #expect(abs(forward - backward) < 1e-12)
}

@Test func placesPointsOnTheCircleAroundTheirCenter() {
    let center = OrbitPoint(x: 2, y: -1)
    let east = OrbitGeometry.point(center: center, radius: 3, angle: 0)

    #expect(abs(east.x - 5) < 1e-9)
    #expect(abs(east.y - (-1)) < 1e-9)
}

/// 우선순위를 모르면 1.0이다. 모르는 값을 크거나 작게 그리면 없는 사실을 말하게 된다.
@Test func fallsBackToNeutralSizeForUnknownPriority() {
    #expect(OrbitGeometry.sizeFactor(forPriority: nil) == 1.0)
    #expect(OrbitGeometry.sizeFactor(forPriority: "긴급") == 1.0)
}

@Test func scalesPlanetsByJiraDefaultPriorities() {
    #expect(OrbitGeometry.sizeFactor(forPriority: "Highest") > OrbitGeometry.sizeFactor(forPriority: "High"))
    #expect(OrbitGeometry.sizeFactor(forPriority: "High") > OrbitGeometry.sizeFactor(forPriority: "Medium"))
    #expect(OrbitGeometry.sizeFactor(forPriority: "Medium") > OrbitGeometry.sizeFactor(forPriority: "Low"))
    #expect(OrbitGeometry.sizeFactor(forPriority: "Low") > OrbitGeometry.sizeFactor(forPriority: "Lowest"))
}

/// Jira 우선순위 이름의 대소문자는 사이트마다 다르다.
@Test func matchesPriorityNamesCaseInsensitively() {
    #expect(OrbitGeometry.sizeFactor(forPriority: "HIGHEST")
            == OrbitGeometry.sizeFactor(forPriority: "Highest"))
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd Packages/Jirarcade && swift test --filter OrbitGeometryTests`
Expected: 컴파일 실패 — `cannot find 'OrbitGeometry' in scope`

- [ ] **Step 3: 최소 구현을 쓴다**

`Packages/Jirarcade/Sources/ArcadeCore/Board/OrbitGeometry.swift`:

```swift
import Foundation

/// 궤도 화면의 논리 좌표 한 점. **pt가 아니다** — 1.0이 궤도 최대 반경이고,
/// 픽셀로 옮기는 일은 뷰가 한다(`OrbitMetrics`).
public struct OrbitPoint: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// 궤도 배치의 기하 계산. 티켓도 화면도 모른다.
public enum OrbitGeometry {
    /// FNV-1a 64비트.
    ///
    /// `String.hashValue`를 쓰지 않는 이유: Swift의 기본 해시는 **프로세스마다 무작위
    /// 시드**를 쓴다. 같은 티켓 키가 앱을 다시 열 때마다 다른 값을 내고, 그러면 어제
    /// 눈여겨본 티켓이 오늘 다른 자리에 있다. 화면은 매 실행 정상으로 보이므로 이 결함은
    /// 눈으로 잡히지 않고, 테스트는 한 프로세스 안에서 도는 탓에 잡지 못한다.
    ///
    /// 표준 라이브러리에는 프로세스 간 안정성을 보장하는 해시가 없으므로 직접 갖는다.
    public static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// 티켓 키를 궤도 위 각도로 옮긴다. 같은 키는 언제나 같은 각도를 얻는다.
    ///
    /// 해시를 100만으로 나눈 나머지를 쓰는 이유는 `UInt64.max`를 `Double`로 옮길 때
    /// 생기는 반올림을 피하기 위해서다. 100만 분해능이면 지름 몇 pt짜리 행성에는
    /// 넉넉하다.
    public static func angle(forKey key: String) -> Double {
        Double(stableHash(key) % 1_000_000) / 1_000_000 * 2 * .pi
    }

    /// 두 각 사이의 **원형** 거리(0…π). 수직선 거리를 쓰면 12시 근처에서
    /// 0.1과 6.2가 멀리 떨어진 것으로 판정돼 그 자리의 행성들이 겹친다.
    public static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let turn = 2 * Double.pi
        let delta = abs(a - b).truncatingRemainder(dividingBy: turn)
        return min(delta, turn - delta)
    }

    /// 극좌표를 논리 좌표로 옮긴다.
    public static func point(center: OrbitPoint, radius: Double, angle: Double) -> OrbitPoint {
        OrbitPoint(x: center.x + radius * cos(angle),
                   y: center.y + radius * sin(angle))
    }

    /// 우선순위를 행성 지름 배율로 옮긴다.
    ///
    /// Jira 기본 우선순위 다섯만 안다. 조직이 이름을 바꿨거나 우선순위를 쓰지 않으면
    /// 1.0이다 — 모르는 값을 크거나 작게 그리면 없는 사실을 말하게 된다.
    public static func sizeFactor(forPriority priority: String?) -> Double {
        switch priority?.lowercased() {
        case "highest": 1.5
        case "high":    1.25
        case "medium":  1.0
        case "low":     0.85
        case "lowest":  0.75
        default:        1.0
        }
    }
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd Packages/Jirarcade && swift test --filter OrbitGeometryTests`
Expected: PASS (9개)

- [ ] **Step 5: 커밋한다**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Board/OrbitGeometry.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/OrbitGeometryTests.swift
git commit -m "feat: 티켓 키에서 궤도 각도를 결정론적으로 계산한다"
```

---

### Task 2: `OrbitPacker` — 원에서의 겹침 해소

같은 태양에 속한 행성이 같은 자리에 겹치지 않게 민다. 보드의 `LanePacker`와 같은 문제이나 원에는 "아랫줄"이 없다.

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Board/OrbitPacker.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/OrbitPackerTests.swift`

**Interfaces:**
- Consumes: `OrbitGeometry.angularDistance(_:_:)` (Task 1)
- Produces:
  - `public struct OrbitSeat: Sendable, Equatable { public let key: String; public let radius: Double; public let angle: Double; public init(key: String, radius: Double, angle: Double) }`
  - `public enum OrbitPacker`
    - `public static func pack(_ seats: [OrbitSeat], planetArc: Double) -> [OrbitSeat]`
    - `public static func minimumAngle(radius: Double, planetArc: Double) -> Double`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Packages/Jirarcade/Tests/ArcadeCoreTests/OrbitPackerTests.swift`:

```swift
import Testing
import Foundation
@testable import ArcadeCore

private let arc = 0.12

private func seat(_ key: String, radius: Double, angle: Double) -> OrbitSeat {
    OrbitSeat(key: key, radius: radius, angle: angle)
}

/// 겹침 판정을 테스트가 직접 다시 정의하지 않는다 — 구현과 같은 규칙을 쓴다.
private func overlaps(_ a: OrbitSeat, _ b: OrbitSeat) -> Bool {
    abs(a.radius - b.radius) < arc
        && OrbitGeometry.angularDistance(a.angle, b.angle)
            < OrbitPacker.minimumAngle(radius: max(a.radius, b.radius), planetArc: arc)
}

@Test func returnsEmptyForEmptyInput() {
    #expect(OrbitPacker.pack([], planetArc: arc).isEmpty)
}

@Test func leavesASingleSeatWhereItIs() {
    let only = seat("DEMO-1", radius: 0.5, angle: 1.0)
    let packed = OrbitPacker.pack([only], planetArc: arc)

    #expect(packed == [only])
}

/// 완전히 같은 자리에 들어온 다섯이 서로 떨어져야 한다. 이게 이 타입의 존재 이유다.
@Test func separatesSeatsThatArrivedAtTheSameSpot() {
    let crowd = (1...5).map { seat("DEMO-\($0)", radius: 0.5, angle: 2.0) }
    let packed = OrbitPacker.pack(crowd, planetArc: arc)

    #expect(packed.count == 5)
    for outer in packed {
        for inner in packed where inner.key != outer.key {
            #expect(!overlaps(outer, inner), "\(outer.key)와 \(inner.key)가 겹친다")
        }
    }
}

/// 입력 순서는 미러 딕셔너리 순회에서 오므로 불안정하다. 결과는 그것과 무관해야 한다.
@Test func packsTheSameRegardlessOfInputOrder() {
    let crowd = (1...5).map { seat("DEMO-\($0)", radius: 0.5, angle: 2.0) }
    let forward = OrbitPacker.pack(crowd, planetArc: arc)
    let backward = OrbitPacker.pack(crowd.reversed(), planetArc: arc)

    #expect(forward == backward)
}

/// 안쪽 궤도는 둘레가 짧아 각도만으로 풀 수 없다. 그때는 반경이 밀린다.
@Test func pushesRadiusOutwardWhenTheInnerRingIsFull() {
    let crowd = (1...8).map { seat("DEMO-\($0)", radius: 0.15, angle: 0.0) }
    let packed = OrbitPacker.pack(crowd, planetArc: arc)

    #expect(packed.contains { $0.radius > 0.15 })
    for outer in packed {
        for inner in packed where inner.key != outer.key {
            #expect(!overlaps(outer, inner), "\(outer.key)와 \(inner.key)가 겹친다")
        }
    }
}

/// 반경이 작을수록 같은 호 길이를 얻는 데 더 큰 각도가 필요하다.
@Test func requiresWiderAnglesOnInnerOrbits() {
    let inner = OrbitPacker.minimumAngle(radius: 0.2, planetArc: arc)
    let outer = OrbitPacker.minimumAngle(radius: 0.9, planetArc: arc)

    #expect(inner > outer)
}

/// 반경 0에서 호 길이를 각도로 나누면 무한대가 된다. π로 막지 않으면 좌석 하나를
/// 놓는 데 무한히 돌거나 NaN이 좌표로 흘러든다.
@Test func clampsMinimumAngleToHalfTurn() {
    #expect(OrbitPacker.minimumAngle(radius: 0, planetArc: arc) <= .pi)
}

/// 이미 흩어져 들어온 좌석은 건드리지 않는다.
@Test func leavesWellSpreadSeatsUntouched() {
    let spread = (0..<4).map { index in
        seat("DEMO-\(index)", radius: 0.6, angle: Double(index) * .pi / 2)
    }
    let packed = OrbitPacker.pack(spread, planetArc: arc)

    #expect(packed.sorted { $0.key < $1.key } == spread.sorted { $0.key < $1.key })
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd Packages/Jirarcade && swift test --filter OrbitPackerTests`
Expected: 컴파일 실패 — `cannot find 'OrbitPacker' in scope`

- [ ] **Step 3: 최소 구현을 쓴다**

`Packages/Jirarcade/Sources/ArcadeCore/Board/OrbitPacker.swift`:

```swift
import Foundation

/// 궤도 위 좌석 하나. 티켓을 모르고 좌표만 안다.
public struct OrbitSeat: Sendable, Equatable {
    public let key: String
    public let radius: Double
    public let angle: Double

    public init(key: String, radius: Double, angle: Double) {
        self.key = key
        self.radius = radius
        self.angle = angle
    }
}

/// 같은 태양에 속한 행성이 서로 가리지 않게 민다.
///
/// 보드의 `LanePacker`와 같은 문제를 원에서 푼다. 다른 점은 **아랫줄이 없다**는 것이다 —
/// 각도로 먼저 풀고, 한 바퀴가 포화했을 때에만 반경을 민다. 반경을 먼저 밀면 정체일과
/// 거리의 대응이 필요 이상으로 어긋난다.
public enum OrbitPacker {
    /// 반경을 미는 횟수의 상한. 궤도 최대 반경 1.0을 가장 작은 `planetArc`로 나눈 것보다
    /// 넉넉하다. 상한이 없으면 잘못된 입력에서 무한 루프가 된다.
    private static let ringLimit = 32

    /// 두 행성이 같은 반경대에서 겹치지 않기 위해 필요한 최소 각거리.
    ///
    /// 호 길이 = 반경 × 각도이므로 각도는 반경에 반비례한다 — 안쪽일수록 더 크게 벌려야
    /// 같은 간격이 난다. π로 막는 이유: 반경이 0에 가까우면 몫이 무한대로 발산해
    /// 좌석 하나를 놓는 데 영원히 돌거나 NaN이 좌표로 흘러든다.
    public static func minimumAngle(radius: Double, planetArc: Double) -> Double {
        guard radius > 0 else { return .pi }
        return min(planetArc / radius, .pi)
    }

    /// 좌석을 키 오름차순으로 하나씩 앉힌다.
    ///
    /// 정렬하는 이유는 입력 순서가 미러 딕셔너리 순회에서 오기 때문이다 —
    /// `BoardLayout`이 미매핑 목록을 정렬하는 것과 같은 이유이며, 정렬하지 않으면
    /// 같은 데이터가 실행마다 다른 배치를 낳는다.
    public static func pack(_ seats: [OrbitSeat], planetArc: Double) -> [OrbitSeat] {
        var placed: [OrbitSeat] = []
        for seat in seats.sorted(by: { $0.key < $1.key }) {
            placed.append(settle(seat, among: placed, planetArc: planetArc))
        }
        return placed
    }

    private static func settle(
        _ seat: OrbitSeat, among placed: [OrbitSeat], planetArc: Double
    ) -> OrbitSeat {
        var radius = seat.radius

        for _ in 0..<ringLimit {
            let step = minimumAngle(radius: radius, planetArc: planetArc)
            // 한 바퀴에 시도할 수 있는 자리 수. step이 π면 두 자리뿐이다.
            let stops = max(Int((2 * Double.pi / step).rounded(.down)), 1)
            var angle = seat.angle

            for _ in 0..<stops {
                if !collides(radius: radius, angle: angle, with: placed, planetArc: planetArc) {
                    return OrbitSeat(key: seat.key, radius: radius, angle: angle)
                }
                angle = (angle + step).truncatingRemainder(dividingBy: 2 * .pi)
            }
            radius += planetArc
        }

        // 여기 닿으면 입력이 비정상이다(같은 자리에 수백 개). 마지막 반경에 원래 각도로
        // 둔다 — 겹칠지언정 화면 밖으로 내보내거나 크래시시키지 않는다.
        return OrbitSeat(key: seat.key, radius: radius, angle: seat.angle)
    }

    private static func collides(
        radius: Double, angle: Double, with placed: [OrbitSeat], planetArc: Double
    ) -> Bool {
        placed.contains { other in
            guard abs(other.radius - radius) < planetArc else { return false }
            let needed = minimumAngle(radius: max(other.radius, radius), planetArc: planetArc)
            return OrbitGeometry.angularDistance(other.angle, angle) < needed
        }
    }
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd Packages/Jirarcade && swift test --filter OrbitPackerTests`
Expected: PASS (8개)

- [ ] **Step 5: 커밋한다**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Board/OrbitPacker.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/OrbitPackerTests.swift
git commit -m "feat: 같은 궤도에 몰린 행성을 각도로 풀고 포화하면 반경을 민다"
```

---

### Task 3: `OrbitLayout` — 도메인 타입과 스냅샷 조립

티켓과 워크플로를 좌표로 옮긴다. 이 계획에서 가장 큰 태스크이고, 여기까지 오면 화면 없이도 궤도 뷰가 옳은지 검증된다.

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Board/OrbitLayout.swift`
- Test: `Packages/Jirarcade/Tests/ArcadeCoreTests/OrbitLayoutTests.swift`

**Interfaces:**
- Consumes:
  - `OrbitPoint`, `OrbitGeometry.angle(forKey:)`, `OrbitGeometry.sizeFactor(forPriority:)`, `OrbitGeometry.point(center:radius:angle:)` (Task 1)
  - `OrbitSeat`, `OrbitPacker.pack(_:planetArc:)` (Task 2)
  - 기존: `ObservedIssue`, `WorkflowMap`, `Stage`, `RuleSet`, `StagnationClassifier`, `StagnationTier`, `DueState`, `BoardAxis.position(forDays:rules:)`, `BoardAxis.ticks(rules:)`, `BoardLayout.visibleStages`, `BoardLayout.dueState(for:now:calendar:)`
- Produces:
  - `public struct OrbitPlanet: Sendable, Equatable, Identifiable`
  - `public struct OrbitSystem: Sendable, Equatable, Identifiable`
  - `public struct OrbitRing: Sendable, Equatable`
  - `public struct OrbitSnapshot: Sendable, Equatable`
  - `public enum OrbitLayout`
    - 상수 `minimumRadius = 0.15`, `stageSpacing = 6.0`, `statusOrbit = 1.5`, `driftOrbit = 8.0`, `planetArc = 0.12`
    - `public static func stageCenter(_ stage: Stage) -> OrbitPoint`
    - `public static func radius(forDays days: Int, rules: RuleSet) -> Double`
    - `public static func snapshot(issues:statusEnteredAt:workflow:rules:zoomProgress:now:calendar:) -> OrbitSnapshot`

`BoardLayout.dueState(for:now:calendar:)`는 현재 `internal`이며 같은 모듈이므로 그대로 부를 수 있다. **`public`으로 올리지 않는다** — 모듈 밖에서 필요한 적이 없다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Packages/Jirarcade/Tests/ArcadeCoreTests/OrbitLayoutTests.swift`:

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

/// `active` 하나에 상태 셋이 접히는 워크플로. 계층 줌이 풀어야 할 상황이며,
/// 실측한 조직에서 배포 파이프라인이 정확히 이 모양이었다(스펙 §1).
private let layeredWorkflow = WorkflowMap(statusToStage: [
    "To Do": .backlog,
    "Dev": .active,
    "Staging": .active,
    "Production": .active,
    "Verifying": .verify,
    "Done": .done,
])

private func snapshot(
    _ issues: [ObservedIssue],
    enteredAt: [String: Date] = [:],
    workflow: WorkflowMap = layeredWorkflow,
    zoom: Double = 1.0,
    rules: RuleSet = .default
) -> OrbitSnapshot {
    OrbitLayout.snapshot(
        issues: issues, statusEnteredAt: enteredAt, workflow: workflow,
        rules: rules, zoomProgress: zoom, now: now, calendar: utc
    )
}

private func system(_ result: OrbitSnapshot, _ statusName: String) -> OrbitSystem? {
    result.systems.first { $0.statusName == statusName }
}

// MARK: - 태양이 되는 것과 되지 않는 것

/// 상태 하나가 태양 하나다. 같은 `Stage`로 접히던 셋이 각자의 태양을 갖는다 —
/// 이것이 보드가 못 하는 일이고 이 화면이 존재하는 이유다.
@Test func makesOneSystemPerStatusNotPerStage() {
    let result = snapshot([
        issue(key: "DEMO-1", status: "Dev"),
        issue(key: "DEMO-2", status: "Staging"),
        issue(key: "DEMO-3", status: "Production"),
    ])

    #expect(result.systems.map(\.statusName) == ["Dev", "Production", "Staging"])
    #expect(result.systems.allSatisfy { $0.stage == .active })
}

/// 티켓이 없는 상태에는 태양이 없다. `BoardLayout`이 `done` 레인을 뺀 것과 같은
/// 이유다 — 영구히 빈 태양 열넷은 뭔가 들어와야 하는데 비어 있다는 잘못된 신호다.
@Test func skipsStatusesThatHaveNoIssues() {
    let result = snapshot([issue(key: "DEMO-1", status: "Dev")])

    #expect(result.systems.map(\.statusName) == ["Dev"])
}

/// 완료 상태의 티켓이 미러에 남아 있어도 태양이 생기지 않는다.
@Test func dropsIssuesInTheDoneStage() {
    let result = snapshot([issue(key: "DEMO-1", status: "Done")])

    #expect(result.systems.isEmpty)
    #expect(result.drifters.isEmpty)
}

/// 매핑되지 않은 상태의 티켓은 떠돌이가 된다. 그냥 버리면 화면에서 조용히 사라지고
/// 사용자는 티켓이 없어졌다고 생각한다.
@Test func sendsUnmappedIssuesToTheDriftRing() {
    let result = snapshot([
        issue(key: "DEMO-9", status: "Blocked"),
        issue(key: "DEMO-1", status: "Dev"),
    ])

    #expect(result.drifters.map(\.issue.key) == ["DEMO-9"])
    #expect(result.systems.map(\.statusName) == ["Dev"])
}

@Test func putsDriftersOnTheOutermostRing() {
    let result = snapshot([issue(key: "DEMO-9", status: "Blocked")])

    #expect(result.drifters.first?.radius == OrbitLayout.driftOrbit)
}

// MARK: - 계층 줌

/// 줌아웃하면 같은 `Stage`의 태양들이 한 점으로 모인다. 태양이 사라지는 것이
/// 아니라 겹치는 것이다 — 그래서 줌 경계에서 화면이 갈아엎히지 않는다.
@Test func collapsesSystemsOfOneStageToASinglePointWhenZoomedOut() {
    let result = snapshot([
        issue(key: "DEMO-1", status: "Dev"),
        issue(key: "DEMO-2", status: "Staging"),
        issue(key: "DEMO-3", status: "Production"),
    ], zoom: 0)

    let centers = result.systems.map(\.center)
    #expect(centers.allSatisfy { $0 == OrbitLayout.stageCenter(.active) })
}

/// 줌인하면 갈라진다. 갈라진 태양들은 서로 궤도가 닿지 않을 만큼 떨어져야 한다.
@Test func spreadsSystemsApartWhenZoomedIn() {
    let result = snapshot([
        issue(key: "DEMO-1", status: "Dev"),
        issue(key: "DEMO-2", status: "Staging"),
        issue(key: "DEMO-3", status: "Production"),
    ], zoom: 1)

    for outer in result.systems {
        for inner in result.systems where inner.statusName != outer.statusName {
            let dx = outer.center.x - inner.center.x
            let dy = outer.center.y - inner.center.y
            #expect((dx * dx + dy * dy).squareRoot() > 2.0,
                    "\(outer.statusName)과 \(inner.statusName)의 궤도가 닿는다")
        }
    }
}

/// 이웃한 `Stage`의 성계끼리도 닿으면 안 된다. 성계 하나의 외곽 반경은
/// 태양 오프셋 1.5 + 궤도 최대 1.0 = 2.5이므로 중심 간 거리가 5.0을 넘어야 한다.
@Test func keepsNeighbouringStagesFromOverlapping() {
    let backlog = OrbitLayout.stageCenter(.backlog)
    let active = OrbitLayout.stageCenter(.active)
    let dx = backlog.x - active.x
    let dy = backlog.y - active.y

    #expect((dx * dx + dy * dy).squareRoot() > 5.0)
}

/// 혼자인 상태는 줌과 무관하게 `Stage` 중심에 있다. 갈라질 상대가 없는데
/// 옆으로 밀려나면 줌할 때 이유 없이 흔들린다.
@Test func leavesALoneSystemAtItsStageCentre() {
    let result = snapshot([issue(key: "DEMO-1", status: "To Do")], zoom: 1)

    #expect(system(result, "To Do")?.center == OrbitLayout.stageCenter(.backlog))
}

@Test func clampsZoomProgressToTheUnitRange() {
    #expect(snapshot([], zoom: -3).zoomProgress == 0)
    #expect(snapshot([], zoom: 9).zoomProgress == 1)
}

// MARK: - 반경은 보드 축과 같은 말을 한다

/// 궤도 반경은 보드 가로축과 **같은 함수**에서 온다. 다른 함수를 쓰면 두 화면이
/// 같은 티켓을 두고 서로 다른 말을 하게 된다.
@Test func derivesRadiusFromTheSameAxisTheBoardUses() {
    let entered = now.addingTimeInterval(-days(21))
    let result = snapshot([issue(key: "DEMO-1", status: "Dev")],
                          enteredAt: ["DEMO-1": entered])

    let expected = OrbitLayout.minimumRadius
        + (1 - OrbitLayout.minimumRadius) * BoardAxis.position(forDays: 21, rules: .default)
    #expect(abs((system(result, "Dev")?.planets.first?.radius ?? 0) - expected) < 1e-9)
}

/// 갓 들어온 티켓도 태양 중심에 박히지 않는다.
@Test func keepsFreshIssuesOffTheStarItself() {
    let result = snapshot([issue(key: "DEMO-1", status: "Dev",
                                 updated: now)])

    #expect(system(result, "Dev")?.planets.first?.radius == OrbitLayout.minimumRadius)
}

/// `RuleSet`은 설정 화면에서 JSON으로 편집할 수 있어 역전된 값이 올 수 있다.
/// `BoardAxis`가 이미 그것을 막고 있으므로 반경도 범위를 벗어나지 않아야 한다.
@Test func keepsRadiusInsideTheOrbitEvenWithInvertedRules() {
    var broken = RuleSet.default
    broken.staleDays = 90
    broken.bossDays = 2
    broken.raidDays = 1

    let result = snapshot([
        issue(key: "DEMO-1", status: "Dev", updated: now.addingTimeInterval(-days(500))),
        issue(key: "DEMO-2", status: "Dev", updated: now),
    ], rules: broken)

    for planet in system(result, "Dev")?.planets ?? [] {
        #expect(planet.radius >= OrbitLayout.minimumRadius)
        #expect(planet.radius <= 1.0 + OrbitLayout.planetArc * 2)
    }
}

/// 동심원은 보드 축의 눈금과 같은 값이다.
@Test func drawsRingsAtTheAxisTicks() {
    let result = snapshot([])

    #expect(result.rings.map(\.days) == BoardAxis.ticks(rules: .default).map(\.days))
    #expect(result.rings.last?.isTerminal == true)
    #expect(result.rings.first?.radius == OrbitLayout.minimumRadius)
}

// MARK: - 자리가 흔들리지 않는다

/// 동기화는 5분마다 돈다. 그때마다 배치가 바뀌면 어제 눈여겨본 티켓을 오늘 찾을 수 없다.
@Test func producesTheSameLayoutForTheSameInput() {
    let issues = (1...6).map { issue(key: "DEMO-\($0)", status: "Dev") }

    #expect(snapshot(issues) == snapshot(issues))
}

/// 입력 순서는 미러 딕셔너리 순회에서 오므로 불안정하다.
@Test func ignoresTheOrderIssuesArriveIn() {
    let issues = (1...6).map { issue(key: "DEMO-\($0)", status: "Dev") }

    #expect(snapshot(issues) == snapshot(issues.reversed()))
}

/// 티켓 하나가 완료돼 미러에서 빠져도 나머지는 제자리에 있어야 한다.
/// 인덱스 기반 균등 배분이었다면 여기서 전부 밀린다.
@Test func keepsOtherPlanetsStillWhenOneIssueDisappears() {
    let issues = (1...6).map { issue(key: "DEMO-\($0)", status: "Dev") }
    let before = snapshot(issues)
    let after = snapshot(issues.filter { $0.key != "DEMO-3" })

    for planet in system(after, "Dev")?.planets ?? [] {
        let old = system(before, "Dev")?.planets.first { $0.id == planet.id }
        #expect(old?.angle == planet.angle, "\(planet.id)의 각도가 움직였다")
        #expect(old?.radius == planet.radius, "\(planet.id)의 반경이 움직였다")
    }
}

/// 같은 상태에 같은 정체일 티켓이 몰려도 서로 가리지 않는다.
@Test func keepsCrowdedPlanetsFromOverlapping() {
    let crowd = (1...12).map { issue(key: "DEMO-\($0)", status: "Dev", updated: now) }
    let planets = system(snapshot(crowd), "Dev")?.planets ?? []

    #expect(planets.count == 12)
    for outer in planets {
        for inner in planets where inner.id != outer.id {
            let sameRing = abs(outer.radius - inner.radius) < OrbitLayout.planetArc
            let needed = OrbitPacker.minimumAngle(radius: max(outer.radius, inner.radius),
                                                  planetArc: OrbitLayout.planetArc)
            let apart = OrbitGeometry.angularDistance(outer.angle, inner.angle) >= needed
            #expect(!sameRing || apart, "\(outer.id)와 \(inner.id)가 겹친다")
        }
    }
}

// MARK: - 행성이 나르는 사실

@Test func carriesTheFactsTheCardNeeds() {
    let due = now.addingTimeInterval(days(2))
    let issues = [ObservedIssue(
        key: "DEMO-1", summary: "샘플", statusName: "Dev", issueType: "개선",
        priority: "Highest", assigneeAccountId: "acc-me", assigneeName: "bahn",
        dueDate: due, jiraUpdatedAt: now.addingTimeInterval(-days(30)),
        sprintCarryOvers: 4, firstSprintName: "DEMO 스프린트 (1)",
        latestSprintName: "DEMO 스프린트 (5)"
    )]
    let planet = system(snapshot(issues), "Dev")?.planets.first

    #expect(planet?.daysStagnant == 30)
    #expect(planet?.tier == .boss)
    #expect(planet?.dueState == .dueIn(days: 2))
    #expect(planet?.sizeFactor == OrbitGeometry.sizeFactor(forPriority: "Highest"))
    #expect(planet?.sprintCarryOvers == 4)
    #expect(planet?.firstSprintName == "DEMO 스프린트 (1)")
    #expect(planet?.isApproximate == true)
}

/// 관측 이력이 있으면 근사가 아니다. 보드 카드가 `~`를 붙이는 기준과 같아야 한다.
@Test func marksPlanetsAsExactWhenObservationHistoryExists() {
    let result = snapshot([issue(key: "DEMO-1", status: "Dev")],
                          enteredAt: ["DEMO-1": now.addingTimeInterval(-days(3))])

    #expect(system(result, "Dev")?.planets.first?.isApproximate == false)
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd Packages/Jirarcade && swift test --filter OrbitLayoutTests`
Expected: 컴파일 실패 — `cannot find 'OrbitLayout' in scope`

- [ ] **Step 3: 최소 구현을 쓴다**

`Packages/Jirarcade/Sources/ArcadeCore/Board/OrbitLayout.swift`:

```swift
import Foundation

/// 태양 하나를 도는 티켓.
///
/// `BoardSlot`과 나르는 사실이 겹치지만 합치지 않는다. 저쪽은 `position`·`row`라는
/// **직교 좌표**를 갖고 이쪽은 `radius`·`angle`이라는 **극좌표**를 갖는다. 하나로 묶으면
/// 두 좌표계가 한 타입에 섞이고, 어느 필드가 유효한지를 타입이 말해 주지 않는다.
public struct OrbitPlanet: Sendable, Equatable, Identifiable {
    public var id: String { issue.key }

    public let issue: ObservedIssue
    /// 클램프 전 **실제** 정체일. 반경은 접혀도 카드는 이 값을 그대로 적는다.
    public let daysStagnant: Int
    public let tier: StagnationTier
    /// 소속 태양 중심 기준 반경. 떠돌이는 원점 기준이다.
    public let radius: Double
    /// 라디안. `[0, 2π)`.
    public let angle: Double
    /// 행성 지름 배율. 우선순위에서 온다.
    public let sizeFactor: Double
    /// 관측 이력이 없어 `jiraUpdatedAt`으로 폴백했다.
    public let isApproximate: Bool
    public let dueState: DueState
    /// 표시 전용이며 채점에 쓰지 않는다.
    public let sprintCarryOvers: Int
    public let firstSprintName: String?
    public let latestSprintName: String?
}

/// 상태 하나 = 태양 하나.
public struct OrbitSystem: Sendable, Equatable, Identifiable {
    public var id: String { statusName }

    public let statusName: String
    public let stage: Stage
    /// `zoomProgress`가 이미 반영된 논리 좌표.
    public let center: OrbitPoint
    public let planets: [OrbitPlanet]
}

/// 등급 경계를 나타내는 동심원. 보드 축의 눈금(`AxisTick`)이 원이 된 것이다.
public struct OrbitRing: Sendable, Equatable {
    public let days: Int
    public let radius: Double
    /// 마지막 원인가. 그 너머가 접혀 있으므로 화면은 "45d+"처럼 적는다.
    public let isTerminal: Bool
}

public struct OrbitSnapshot: Sendable, Equatable {
    public let systems: [OrbitSystem]
    /// 어느 태양에도 속하지 못한 티켓. 성계 전체를 감싸는 바깥 고리를 떠돈다.
    public let drifters: [OrbitPlanet]
    public let rings: [OrbitRing]
    /// 0이면 `Stage` 넷으로 뭉쳐 보이고 1이면 상태별로 갈라진다.
    public let zoomProgress: Double
}

/// 미러와 워크플로를 궤도 좌표로 옮긴다. 순수 함수이며 화면을 모른다.
///
/// pt도 픽셀도 줌 배율도 제스처도 모른다 — 돌려주는 것은 **논리 좌표**이고
/// 1.0이 궤도 최대 반경이다. 픽셀로 옮기는 일은 `OrbitMetrics`가 한다.
public enum OrbitLayout {
    /// 정체 0일 티켓이 태양 중심에 박히지 않게 하는 하한.
    ///
    /// 하필 0.15인 이유: 그보다 작으면 갓 들어온 티켓 여럿이 좁은 원에 몰려
    /// `OrbitPacker`가 곧바로 반경을 밀어내기 시작한다.
    public static let minimumRadius = 0.15

    /// `Stage` 중심 사이의 거리.
    ///
    /// 줌인했을 때 한 성계가 차지하는 외곽 반경은 `statusOrbit`(1.5) + 궤도 최대(1.0)
    /// = 2.5다. 이웃한 두 성계가 닿지 않으려면 중심 간 거리가 5.0을 넘어야 하고,
    /// 여유 1.0을 더해 6.0으로 잡는다. **비교 대상은 궤도 반경이 아니라 성계의 외곽
    /// 반경이다** — 이걸 혼동하면 줌인에서 이웃 `Stage`의 행성끼리 겹친다.
    public static let stageSpacing = 6.0

    /// 상태 태양이 소속 `Stage` 중심에서 떨어지는 거리(줌 100% 기준).
    public static let statusOrbit = 1.5

    /// 떠돌이 고리의 반경. `Stage` 중심의 대각 거리(3√2 ≈ 4.24)에 외곽 반경 2.5를
    /// 더한 6.74보다 바깥이어야 성계 위를 지나가지 않는다.
    public static let driftOrbit = 8.0

    /// 행성 하나가 차지하는 호 길이(논리 단위). **줌과 무관한 상수다** —
    /// 줌에 따라 달라지면 확대할 때마다 배치가 다시 계산돼 행성이 미끄러진다.
    public static let planetArc = 0.12

    /// `Stage` 넷의 2×2 배치. 순서는 `BoardLayout.visibleStages`와 같아서
    /// 레인에서 궤도로 전환할 때 위아래 순서가 유지된다.
    public static func stageCenter(_ stage: Stage) -> OrbitPoint {
        let half = stageSpacing / 2
        return switch stage {
        case .backlog: OrbitPoint(x: -half, y: -half)
        case .active:  OrbitPoint(x:  half, y: -half)
        case .review:  OrbitPoint(x: -half, y:  half)
        case .verify:  OrbitPoint(x:  half, y:  half)
        // 보드와 같이 `done`은 그리지 않는다. 여기 닿는 경로는 없지만
        // 열거형이 늘어날 때 컴파일러가 알려주도록 케이스를 남긴다.
        case .done:    OrbitPoint(x: 0, y: 0)
        }
    }

    /// 정체일을 궤도 반경으로 옮긴다.
    ///
    /// **보드 축과 같은 함수를 쓴다.** 다른 함수를 쓰면 두 화면이 같은 티켓을 두고
    /// 서로 다른 말을 하고, 설정에서 `RuleSet`을 고쳤을 때 한쪽만 움직인다.
    /// 덤으로 구간별 선형 성질을 그대로 얻는다 — 단순 선형이면 0–7일 구간이 축의
    /// 15%에 불과해 대부분의 티켓이 태양에 달라붙는데, 안쪽일수록 원 둘레가 짧아
    /// 원에서는 그 문제가 더 심하다.
    public static func radius(forDays days: Int, rules: RuleSet) -> Double {
        minimumRadius + (1 - minimumRadius) * BoardAxis.position(forDays: days, rules: rules)
    }

    public static func snapshot(
        issues: [ObservedIssue],
        statusEnteredAt: [String: Date],
        workflow: WorkflowMap,
        rules: RuleSet,
        zoomProgress: Double,
        now: Date,
        calendar: Calendar
    ) -> OrbitSnapshot {
        let zoom = min(max(zoomProgress, 0), 1)
        let classifier = StagnationClassifier(rules: rules)

        func makePlanet(_ issue: ObservedIssue, seat: OrbitSeat) -> OrbitPlanet {
            let entered = statusEnteredAt[issue.key]
            return OrbitPlanet(
                issue: issue,
                daysStagnant: classifier.daysStagnant(
                    statusEnteredAt: entered, jiraUpdatedAt: issue.jiraUpdatedAt, now: now
                ),
                tier: classifier.classify(
                    statusEnteredAt: entered, jiraUpdatedAt: issue.jiraUpdatedAt, now: now
                ),
                radius: seat.radius,
                angle: seat.angle,
                sizeFactor: OrbitGeometry.sizeFactor(forPriority: issue.priority),
                isApproximate: classifier.isApproximate(statusEnteredAt: entered),
                dueState: BoardLayout.dueState(for: issue, now: now, calendar: calendar),
                sprintCarryOvers: issue.sprintCarryOvers,
                firstSprintName: issue.firstSprintName,
                latestSprintName: issue.latestSprintName
            )
        }

        var byStatus: [String: [ObservedIssue]] = [:]
        var stageOf: [String: Stage] = [:]
        var unmapped: [ObservedIssue] = []

        for issue in issues {
            guard let stage = workflow.stage(for: issue.statusName) else {
                unmapped.append(issue)
                continue
            }
            guard BoardLayout.visibleStages.contains(stage) else { continue }
            byStatus[issue.statusName, default: []].append(issue)
            stageOf[issue.statusName] = stage
        }

        // 상태명 오름차순으로 태양을 늘어놓는다. 딕셔너리 순회 순서를 쓰면
        // 같은 데이터가 실행마다 다른 배치를 낳는다.
        var systems: [OrbitSystem] = []
        for stage in BoardLayout.visibleStages {
            let names = byStatus.keys.filter { stageOf[$0] == stage }.sorted()
            for (index, name) in names.enumerated() {
                let center = statusCentre(
                    stage: stage, index: index, count: names.count, zoom: zoom
                )
                let seats = OrbitPacker.pack(
                    (byStatus[name] ?? []).map { issue in
                        OrbitSeat(
                            key: issue.key,
                            radius: radius(
                                forDays: classifier.daysStagnant(
                                    statusEnteredAt: statusEnteredAt[issue.key],
                                    jiraUpdatedAt: issue.jiraUpdatedAt, now: now
                                ),
                                rules: rules
                            ),
                            angle: OrbitGeometry.angle(forKey: issue.key)
                        )
                    },
                    planetArc: planetArc
                )
                let bySeatKey = Dictionary(
                    uniqueKeysWithValues: (byStatus[name] ?? []).map { ($0.key, $0) }
                )
                systems.append(OrbitSystem(
                    statusName: name,
                    stage: stage,
                    center: center,
                    planets: seats.compactMap { seat in
                        bySeatKey[seat.key].map { makePlanet($0, seat: seat) }
                    }
                ))
            }
        }

        let driftSeats = OrbitPacker.pack(
            unmapped.map {
                OrbitSeat(key: $0.key, radius: driftOrbit,
                          angle: OrbitGeometry.angle(forKey: $0.key))
            },
            planetArc: planetArc
        )
        let driftByKey = Dictionary(uniqueKeysWithValues: unmapped.map { ($0.key, $0) })

        return OrbitSnapshot(
            systems: systems,
            drifters: driftSeats.compactMap { seat in
                driftByKey[seat.key].map { makePlanet($0, seat: seat) }
            },
            rings: BoardAxis.ticks(rules: rules).map {
                OrbitRing(days: $0.days,
                          radius: minimumRadius + (1 - minimumRadius) * $0.position,
                          isTerminal: $0.isTerminal)
            },
            zoomProgress: zoom
        )
    }

    /// 상태 태양 하나의 자리. 줌아웃할수록 소속 `Stage` 중심으로 수렴한다.
    ///
    /// 혼자면 오프셋이 0이다 — 갈라질 상대가 없는데 옆으로 밀려나면 줌할 때
    /// 이유 없이 흔들린다.
    private static func statusCentre(
        stage: Stage, index: Int, count: Int, zoom: Double
    ) -> OrbitPoint {
        let base = stageCenter(stage)
        guard count > 1 else { return base }
        let angle = 2 * Double.pi * Double(index) / Double(count)
        return OrbitPoint(
            x: base.x + statusOrbit * cos(angle) * zoom,
            y: base.y + statusOrbit * sin(angle) * zoom
        )
    }
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd Packages/Jirarcade && swift test --filter OrbitLayoutTests`
Expected: PASS (21개)

- [ ] **Step 5: 전체 테스트가 여전히 통과하는지 확인한다**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS. 기존 테스트 수 + 38개.

- [ ] **Step 6: 커밋한다**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Board/OrbitLayout.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/OrbitLayoutTests.swift
git commit -m "feat: 티켓과 워크플로를 상태별 태양계 좌표로 옮긴다"
```

---

### Task 4: `AppModel.orbitSnapshot` — 뷰에 시계를 주지 않는 경로

궤도 좌표를 만드는 입구를 `AppModel`에 낸다. 그리고 그 과정에서 드러난 낙관적 사본의 누락 필드를 함께 고친다.

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift` (`boardSnapshot` 아래, `optimisticIssues` 안)
- Test: `Packages/Jirarcade/Tests/ArcadeAppTests/AppModelTests.swift` (추가)

**Interfaces:**
- Consumes: `OrbitLayout.snapshot(...)`, `OrbitSnapshot` (Task 3)
- Produces: `public func orbitSnapshot(zoomProgress: Double) -> OrbitSnapshot`

**함께 고치는 결함:** `optimisticIssues`가 전이 대기 중인 티켓의 사본을 만들 때 `sprintCarryOvers`·`firstSprintName`·`latestSprintName`을 넘기지 않는다. `ObservedIssue.init`이 기본값(`0`/`nil`)을 갖고 있어 컴파일은 통과하지만, **상태를 옮기는 5초 동안 카드에서 이월 줄이 사라졌다가 돌아온다.** 궤도 뷰도 같은 목록을 읽으므로 여기서 함께 고친다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Packages/Jirarcade/Tests/ArcadeAppTests/AppModelTests.swift` 끝에 덧붙인다. 이 파일이 이미 쓰고 있는 헬퍼(모델을 만들고 미러를 채우는 함수)를 그대로 쓴다 — 파일 앞부분을 먼저 읽고 그 이름을 확인할 것.

```swift
// MARK: - 궤도 스냅샷

/// 뷰는 `Date()`를 부르지 않는다. 시계와 달력은 모델이 주입한다 —
/// `boardSnapshot`이 그렇게 하는 이유와 같다.
@Test func buildsAnOrbitSnapshotFromTheSameMirrorTheBoardUses() async throws {
    let model = try await makeSignedInModel(issues: [
        stubIssue(key: "DEMO-1", status: "In Progress"),
    ])

    let orbit = model.orbitSnapshot(zoomProgress: 1)

    #expect(orbit.systems.map(\.statusName) == ["In Progress"])
    #expect(orbit.systems.first?.planets.map(\.id) == ["DEMO-1"])
}

/// 대기 중인 전이가 궤도에도 곧바로 보여야 한다. `issues`를 직접 읽으면
/// 카드에서 상태를 옮겨도 행성이 5초 동안 옛 태양에 남는다.
@Test func showsPendingTransitionsInTheOrbitImmediately() async throws {
    let model = try await makeSignedInModel(issues: [
        stubIssue(key: "DEMO-1", status: "To Do"),
    ])

    model.requestTransition(issueKey: "DEMO-1",
                            transition: JiraTransition(id: "1", name: "시작",
                                                       toStatusName: "In Progress"))

    let orbit = model.orbitSnapshot(zoomProgress: 1)
    #expect(orbit.systems.map(\.statusName) == ["In Progress"])
}

/// 낙관적 사본이 스프린트 세 값을 떨어뜨리면, 상태를 옮기는 5초 동안
/// 카드의 이월 줄이 사라졌다가 돌아온다.
@Test func keepsSprintFactsWhileATransitionIsPending() async throws {
    let model = try await makeSignedInModel(issues: [
        stubIssue(key: "DEMO-1", status: "To Do",
                  sprintCarryOvers: 4,
                  firstSprintName: "DEMO 스프린트 (1)",
                  latestSprintName: "DEMO 스프린트 (5)"),
    ])

    model.requestTransition(issueKey: "DEMO-1",
                            transition: JiraTransition(id: "1", name: "시작",
                                                       toStatusName: "In Progress"))

    let slot = model.boardSnapshot(minimumSpacing: 0)
        .lanes.flatMap(\.slots).first { $0.id == "DEMO-1" }
    #expect(slot?.sprintCarryOvers == 4)
    #expect(slot?.firstSprintName == "DEMO 스프린트 (1)")
    #expect(slot?.latestSprintName == "DEMO 스프린트 (5)")
}
```

**주의:** `makeSignedInModel`·`stubIssue`·`JiraTransition`의 실제 이름과 시그니처는 `Tests/ArcadeAppTests/TestSupport.swift`와 `AppModelTests.swift` 앞부분에 있다. 위 코드는 그 헬퍼가 있다고 가정한다 — 이름이 다르면 **테스트를 그 파일의 관행에 맞추고, 헬퍼를 새로 만들지 않는다.** `stubIssue`가 스프린트 세 값을 받지 않으면 기본값 파라미터로 더한다.

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd Packages/Jirarcade && swift test --filter AppModelTests`
Expected: 앞의 둘은 컴파일 실패(`orbitSnapshot`이 없다), 셋째는 FAIL(`sprintCarryOvers`가 0)

- [ ] **Step 3: `orbitSnapshot`을 더한다**

`AppModel.swift`의 `boardSnapshot(minimumSpacing:)` 바로 아래에 넣는다:

```swift
    /// 궤도 뷰가 그릴 좌표. `boardSnapshot`과 같은 미러·같은 시계를 쓴다.
    ///
    /// 뷰가 `OrbitLayout.snapshot`을 직접 부르지 않는 이유는 그 함수가 `now`와
    /// `calendar`를 받기 때문이다 — `ArcadeUI`에는 시계가 없어야 한다.
    ///
    /// - Parameter zoomProgress: 0이면 `Stage` 넷으로 뭉쳐 보이고 1이면 상태별로
    ///   갈라진다. 뷰가 줌 배율에서 계산해 넘긴다.
    public func orbitSnapshot(zoomProgress: Double) -> OrbitSnapshot {
        OrbitLayout.snapshot(
            issues: optimisticIssues,
            statusEnteredAt: statusEnteredAt,
            workflow: boardWorkflow,
            rules: rules,
            zoomProgress: zoomProgress,
            now: clock(),
            calendar: calendar
        )
    }
```

- [ ] **Step 4: 낙관적 사본의 누락 필드를 채운다**

`optimisticIssues` 안의 `ObservedIssue(...)` 생성자에 세 인자를 더한다:

```swift
            return ObservedIssue(
                key: issue.key, summary: issue.summary,
                statusName: pending.toStatusName, issueType: issue.issueType,
                priority: issue.priority, assigneeAccountId: issue.assigneeAccountId,
                assigneeName: issue.assigneeName, dueDate: issue.dueDate,
                jiraUpdatedAt: issue.jiraUpdatedAt,
                // 이 셋을 넘기지 않으면 `init`의 기본값(0/nil)이 들어가, 전이를 기다리는
                // 5초 동안 카드에서 이월 줄이 사라졌다가 돌아온다. 상태만 바꾼 사본이므로
                // 스프린트 이력은 원본 그대로여야 한다.
                sprintCarryOvers: issue.sprintCarryOvers,
                firstSprintName: issue.firstSprintName,
                latestSprintName: issue.latestSprintName
            )
```

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

Run: `cd Packages/Jirarcade && swift test --filter AppModelTests`
Expected: PASS

- [ ] **Step 6: 전체 테스트를 돌린다**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS. `ModuleBoundaryTests.arcadeAppNeverImportsSwiftUI`가 여전히 통과해야 한다 — `OrbitSnapshot`은 `ArcadeCore` 타입이므로 SwiftUI를 들이지 않는다.

- [ ] **Step 7: 커밋한다**

두 변경은 성격이 다르므로 커밋을 가른다.

```bash
git add Packages/Jirarcade/Sources/ArcadeApp/AppModel.swift
git commit -m "fix: 전이를 기다리는 사이에도 스프린트 이력을 잃지 않는다

낙관적 사본이 상태명만 바꾼 ObservedIssue를 만들면서 스프린트 세 값을
넘기지 않았다. init의 기본값이 0/nil이라 컴파일은 통과하지만, 상태를
옮기는 5초 동안 카드의 이월 줄이 사라졌다가 돌아온다."

git add Packages/Jirarcade/Tests/ArcadeAppTests/AppModelTests.swift
git commit -m "feat: 궤도 좌표를 만드는 입구를 모델에 낸다"
```

---

### Task 5: `OrbitMetrics`와 `PlanetView` — 논리 좌표를 화면으로

논리 좌표를 pt로 옮기는 곱셈과, 행성 한 개를 그리는 뷰를 만든다. `ArcadeUI`에는 테스트 타깃이 없으므로 이 태스크부터는 **빌드 + 눈으로 확인**이 검증이다. 판단은 이미 `ArcadeCore`에서 끝났고 여기 남은 것은 곱셈뿐이라 위험이 낮다 — `BoardMetrics`가 같은 이유로 같은 모양이다.

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/OrbitMetrics.swift`
- Create: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/PlanetView.swift`

**Interfaces:**
- Consumes: `OrbitPoint`, `OrbitPlanet`, `OrbitSystem`, `OrbitSnapshot.extent`, `OrbitLayout.planetArc` (Task 1·3), `ArcadeMetrics`, `ArcadeTheme`
- Produces:
  - `struct OrbitMetrics` — `init(viewport:scale:pan:extent:)`, `static func fitScale(viewport:extent:) -> Double`, `static func minScale(viewport:extent:)`, `static func maxScale(viewport:extent:)`, `var zoomProgress: Double`, `func point(_:) -> CGPoint`, `func planetPoint(system:planet:) -> CGPoint`, `func driftPoint(_:) -> CGPoint`, `func diameter(for:) -> Double`, `func length(_:) -> Double`, `var showsPlanetLabels: Bool`
  - `struct PlanetView: View` — `init(planet:diameter:isPending:)`

- [ ] **Step 1: `OrbitMetrics`를 만든다**

```swift
import SwiftUI
import ArcadeCore

/// 논리 좌표(1.0 = 궤도 최대 반경)를 pt로 옮기는 곱셈만 모은 값 타입.
///
/// 판단은 `OrbitLayout`이 이미 끝냈다 — 여기에는 등급 판정도 정렬도 겹침 해소도 없다.
/// `BoardMetrics`가 같은 이유로 같은 모양이다.
struct OrbitMetrics {
    let viewport: CGSize
    /// 논리 1.0이 몇 pt인가.
    let scale: Double
    let pan: CGSize
    /// 성계 전체가 들어가는 논리 반지름. `OrbitSnapshot.extent`에서 온다.
    let extent: Double

    /// 성계 넷이 모두 들어오는 배율.
    ///
    /// `extent`는 스냅샷이 알려준다 — **상수로 둘 수 없다.** 성계의 크기가 그 `Stage`에
    /// 접힌 상태 수에 따라 달라지기 때문이다(`OrbitLayout.statusOrbit(count:)`). 상태가
    /// 여덟인 조직과 둘인 조직은 논리 좌표에서 성계 크기가 두 배 넘게 차이 난다.
    ///
    /// 지름(`extent * 2`)에 가장자리 여백 2.0을 더한 값으로 나눈다. 떠돌이 고리는
    /// `extent`에 들어 있지 않다 — 미매핑 상태가 없는 것이 정상이고, 있을 때를 기준으로
    /// 배율을 잡으면 평소에 성계가 화면 한가운데 작게 뭉친다.
    static func fitScale(viewport: CGSize, extent: Double) -> Double {
        min(viewport.width, viewport.height) / max(extent * 2 + 2.0, 1)
    }

    static func minScale(viewport: CGSize, extent: Double) -> Double {
        fitScale(viewport: viewport, extent: extent) * 0.6
    }

    static func maxScale(viewport: CGSize, extent: Double) -> Double {
        fitScale(viewport: viewport, extent: extent) * 6
    }

    /// 태양이 상태별로 다 갈라지는 배율.
    private static func spreadScale(viewport: CGSize, extent: Double) -> Double {
        fitScale(viewport: viewport, extent: extent) * 2.5
    }

    /// `OrbitLayout.snapshot`에 넘길 값. 기본 배율에서 0이고 2.5배에서 1이다.
    ///
    /// **닭과 달걀:** `extent`는 스냅샷에서 오는데 스냅샷을 만들려면 `zoomProgress`가
    /// 필요하다. 끊는 자리는 여기다 — `extent`는 어느 `Stage`에 상태가 몇 개인지에서만
    /// 나오고 줌과 무관하므로, 뷰는 `zoomProgress: 0`으로 스냅샷을 한 번 만들어
    /// `extent`를 얻은 뒤 실제 줌으로 다시 만든다. 둘 다 순수 함수라 값이 흔들리지 않는다.
    var zoomProgress: Double {
        let base = Self.fitScale(viewport: viewport, extent: extent)
        let spread = Self.spreadScale(viewport: viewport, extent: extent)
        guard spread > base else { return 1 }
        return min(max((scale - base) / (spread - base), 0), 1)
    }

    /// 티켓 키를 행성 옆에 적을 만큼 확대했는가. 줌아웃 상태에서 키 수십 개를 겹쳐
    /// 그리면 읽을 수 없는 글자 덩어리가 된다.
    var showsPlanetLabels: Bool { zoomProgress > 0.5 }

    func length(_ logical: Double) -> Double { logical * scale }

    func point(_ logical: OrbitPoint) -> CGPoint {
        CGPoint(x: viewport.width / 2 + logical.x * scale + pan.width,
                y: viewport.height / 2 + logical.y * scale + pan.height)
    }

    func planetPoint(system: OrbitSystem, planet: OrbitPlanet) -> CGPoint {
        point(OrbitGeometry.point(center: system.center,
                                  radius: planet.radius, angle: planet.angle))
    }

    /// 떠돌이는 소속 태양이 없다. 원점을 감싸는 바깥 고리에 놓인다.
    func driftPoint(_ planet: OrbitPlanet) -> CGPoint {
        point(OrbitGeometry.point(center: OrbitPoint(x: 0, y: 0),
                                  radius: planet.radius, angle: planet.angle))
    }

    /// 행성 지름. 줌에 비례해 커진다 — 확대했는데 점 크기가 그대로면
    /// 가까이 간 느낌이 나지 않는다.
    func diameter(for planet: OrbitPlanet) -> Double {
        length(OrbitLayout.planetArc) * planet.sizeFactor
    }
}
```

- [ ] **Step 2: `PlanetView`를 만든다**

```swift
import SwiftUI
import ArcadeCore

/// 궤도 위의 티켓 한 개.
///
/// 등급을 색에 대응시키는 방식은 `TicketCardView`와 **같아야 한다** — 두 화면이
/// 같은 티켓을 다른 색으로 그리면 어느 쪽이 맞는지 알 수 없다. raid를 boss와 색으로
/// 가르지 않고 채움으로 가르는 것도 그 파일의 판단을 그대로 따른 것이다.
struct PlanetView: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let planet: OrbitPlanet
    let diameter: Double
    /// 전이를 기다리는 중인가. 카드의 대기 표시에 대응한다.
    let isPending: Bool

    /// raid 등급의 아주 느린 맥동. 이 화면의 유일한 상시 움직임이다.
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(fill)
            .overlay(Circle().strokeBorder(tierColor, lineWidth: strokeWidth))
            .overlay(dueRing)
            .frame(width: diameter, height: diameter)
            .opacity(isPending ? 0.5 : 1)
            .scaleEffect(pulsing ? 1.12 : 1)
            .onAppear {
                guard planet.tier == .raid, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            .accessibilityLabel(accessibilityLabel)
    }

    /// raid만 채운다. 팔레트에 raid 전용 토큰이 없고, 있어야 할 이유도 없다 —
    /// boss와 raid를 색으로 가르면 `ContrastTests`를 통과할 색 하나가 더 필요해진다.
    private var fill: Color {
        planet.tier == .raid ? theme.boss : theme.surfaceRaised
    }

    private var strokeWidth: Double {
        planet.tier >= .boss ? 2 : 1
    }

    private var tierColor: Color {
        switch planet.tier {
        case .fresh: theme.line
        case .stale: theme.accent
        case .boss, .raid: theme.boss
        }
    }

    /// 마감 임박은 드물게 켜지는 신호이므로 상시 손잡이가 아니라 바깥 링으로 그린다.
    /// D-3을 경계로 삼는 판단은 뷰의 몫이다 — `DueState`는 사실만 담는다.
    @ViewBuilder private var dueRing: some View {
        if case .dueIn(let days) = planet.dueState, days <= 3 {
            Circle()
                .strokeBorder(theme.danger, lineWidth: 1)
                .padding(-3)
        } else if case .overdue = planet.dueState {
            Circle()
                .strokeBorder(theme.danger, lineWidth: 2)
                .padding(-3)
        }
    }

    private var accessibilityLabel: String {
        let stagnation = (planet.isApproximate ? "약 " : "") + "\(planet.daysStagnant)일"
        return "\(planet.issue.key), \(planet.issue.summary), 정체 \(stagnation)"
    }
}
```

- [ ] **Step 3: 빌드한다**

Run: `cd Packages/Jirarcade && swift build`
Expected: 성공. 아직 화면에 붙지 않았으므로 눈에 보이는 변화는 없다.

- [ ] **Step 4: 색 리터럴 검사를 통과하는지 확인한다**

Run: `cd Packages/Jirarcade && swift test --filter ModuleBoundaryTests`
Expected: PASS. 실패하면 `PlanetView`에 `.primary`나 hex가 들어간 것이다 — 전부 `theme`에서 받아야 한다.

- [ ] **Step 5: 커밋한다**

```bash
git add Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/OrbitMetrics.swift \
        Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/PlanetView.swift
git commit -m "feat: 논리 좌표를 pt로 옮기고 행성 하나를 그린다"
```

---

### Task 6: `OrbitView` — 태양·궤도·팬·줌

성계를 화면에 그리고 제스처를 붙인다. 이 태스크가 끝나면 궤도가 실제로 보인다(아직 토글은 없으므로 임시 배선으로 확인한다).

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/OrbitView.swift`
- Create: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/PlanetPopover.swift`

**Interfaces:**
- Consumes: `OrbitMetrics`, `PlanetView` (Task 5), `AppModel.orbitSnapshot(zoomProgress:)` (Task 4), `AtlassianLinks.issue(key:site:)`, `AppModel.siteHost`
- Produces:
  - `struct OrbitView: View` — `init(model: AppModel, cardNamespace: Namespace.ID)`
  - `struct PlanetPopover: View` — `init(planet: OrbitPlanet, siteHost: String?)`

- [ ] **Step 1: `PlanetPopover`를 만든다**

카드와 **같은 사실을 같은 표기로** 적는다. 근사 표시 `~`, 이월 문구 `↻ 스프린트 N회`는 `TicketCardView`가 쓰는 것 그대로다 — 두 화면이 같은 티켓을 다르게 적으면 어느 쪽이 맞는지 알 수 없다.

```swift
import SwiftUI
import ArcadeCore

/// 행성을 눌렀을 때 뜨는 읽기 전용 요약.
///
/// `TicketCardView`를 재사용하지 않는 이유는 그 뷰가 상태 옮기기 메뉴와 5초 실행 취소
/// UI를 품고 있기 때문이다 — 궤도는 보는 화면이고 전이는 레인에서 한다(스펙 §12).
/// 대신 표기는 카드와 맞춘다.
struct PlanetPopover: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
    let planet: OrbitPlanet
    let siteHost: String?

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowGap) {
            HStack(spacing: metrics.tightGap) {
                Text(tierLabel)
                    .arcadeType(.readout, .xs, weight: .bold)
                    .foregroundStyle(tierColor)
                Spacer()
                Text(stagnationLabel)
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.inkTertiary)
                    .monospacedDigit()
            }
            Text(planet.issue.key)
                .arcadeType(.readout, .s, weight: .bold)
                .foregroundStyle(theme.inkPrimary)
            Text(planet.issue.summary)
                .arcadeType(.prose, .xs)
                .foregroundStyle(theme.inkSecondary)
                .lineLimit(3)
            if let dueLabel {
                Text(dueLabel)
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.danger)
            }
            if planet.sprintCarryOvers > 0 {
                // 문구는 `TicketCardView`와 같아야 한다.
                Text("↻ 스프린트 \(planet.sprintCarryOvers)회")
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.inkTertiary)
                    .help(sprintTooltip)
            }
            if let site = siteHost, let url = AtlassianLinks.issue(key: planet.issue.key, site: site) {
                Link("Jira에서 열기", destination: url)
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(metrics.sectionGap)
        .frame(width: metrics.size(.ticketCardWidth))
    }

    private var tierLabel: String {
        switch planet.tier {
        case .fresh: "·"
        case .stale: "STALE"
        case .boss:  "BOSS"
        case .raid:  "RAID"
        }
    }

    private var tierColor: Color {
        switch planet.tier {
        case .fresh: theme.line
        case .stale: theme.accent
        case .boss, .raid: theme.boss
        }
    }

    /// 관측 이력이 없는 티켓의 정체일을 확정처럼 보여주면 "관측한 것만 안다"는
    /// 이 앱의 원칙이 화면에서 깨진다. 카드와 같은 규칙이다.
    private var stagnationLabel: String {
        (planet.isApproximate ? "~" : "") + "\(planet.daysStagnant)d"
    }

    private var dueLabel: String? {
        switch planet.dueState {
        case .none: nil
        case .dueIn(let days): "D-\(days)"
        case .overdue(let days): "\(days)일 지남"
        }
    }

    private var sprintTooltip: String {
        guard let first = planet.firstSprintName, let latest = planet.latestSprintName
        else { return "" }
        return "\(first) → \(latest)"
    }
}
```

- [ ] **Step 2: `OrbitView`를 만든다**

```swift
import SwiftUI
import ArcadeApp
import ArcadeCore

/// 상태별 태양계.
///
/// 좌표는 전부 `OrbitLayout`이 정했다. 이 뷰가 하는 일은 논리 좌표를 pt로 옮겨
/// 놓는 것과 제스처를 받는 것뿐이다.
struct OrbitView: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: AppModel
    let cardNamespace: Namespace.ID

    /// nil이면 "전체가 보이는 배율". 창 크기가 바뀌어도 따라가게 하려고
    /// 절대값 대신 nil을 기본으로 둔다.
    @State private var scale: Double?
    @State private var committedPan: CGSize = .zero
    @State private var dragPan: CGSize = .zero
    @State private var gestureScale: Double = 1
    @State private var selected: String?

    var body: some View {
        GeometryReader { proxy in
            // 성계가 논리 좌표에서 얼마나 큰지 먼저 잰다. 크기는 어느 `Stage`에 상태가
            // 몇 개 접혔는지에서만 나오고 줌과 무관하므로, 줌 0으로 한 번 만들어
            // `extent`를 얻고 그 값으로 배율을 정한 뒤 실제 줌으로 다시 만든다.
            // 순수 함수 두 번이라 값이 흔들리지 않는다.
            let extent = model.orbitSnapshot(zoomProgress: 0).extent
            let base = scale ?? OrbitMetrics.fitScale(viewport: proxy.size, extent: extent)
            let metrics = OrbitMetrics(
                viewport: proxy.size,
                scale: clampScale(base * gestureScale, viewport: proxy.size, extent: extent),
                pan: CGSize(width: committedPan.width + dragPan.width,
                            height: committedPan.height + dragPan.height),
                extent: extent
            )
            let snapshot = model.orbitSnapshot(zoomProgress: metrics.zoomProgress)

            ZStack {
                ForEach(snapshot.systems) { system in
                    systemView(system, snapshot: snapshot, metrics: metrics)
                }
                driftView(snapshot, metrics: metrics)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(pan(viewport: proxy.size))
            .gesture(magnify(viewport: proxy.size, extent: extent))
            .background(theme.surfaceBase)
            .overlay(alignment: .bottomTrailing) {
                zoomControls(viewport: proxy.size, extent: extent)
            }
        }
    }

    // MARK: - 그리기

    @ViewBuilder
    private func systemView(
        _ system: OrbitSystem, snapshot: OrbitSnapshot, metrics: OrbitMetrics
    ) -> some View {
        let centre = metrics.point(system.center)

        // 등급 경계 동심원. 보드의 축 눈금이 원이 된 것이다.
        ForEach(snapshot.rings, id: \.days) { ring in
            Circle()
                .strokeBorder(theme.line, lineWidth: 0.5)
                .frame(width: metrics.length(ring.radius) * 2,
                       height: metrics.length(ring.radius) * 2)
                .position(centre)
                .opacity(0.5)
        }

        // 태양. 이름은 항상 보인다.
        VStack(spacing: density.tightGap) {
            Circle()
                .fill(theme.accent)
                .frame(width: metrics.length(OrbitLayout.planetArc) * 1.4,
                       height: metrics.length(OrbitLayout.planetArc) * 1.4)
            Text(system.statusName)
                .arcadeType(.readout, .xs, weight: .bold)
                .foregroundStyle(theme.inkSecondary)
                .fixedSize()
        }
        .position(centre)

        ForEach(system.planets) { planet in
            planetButton(planet, at: metrics.planetPoint(system: system, planet: planet),
                         metrics: metrics)
        }
    }

    /// 어느 태양에도 속하지 못한 티켓. 성계 전체를 감싸는 바깥 고리를 떠돈다.
    /// 그냥 버리면 화면에서 조용히 사라지고 사용자는 티켓이 없어졌다고 생각한다.
    @ViewBuilder
    private func driftView(_ snapshot: OrbitSnapshot, metrics: OrbitMetrics) -> some View {
        ForEach(snapshot.drifters) { planet in
            planetButton(planet, at: metrics.driftPoint(planet), metrics: metrics)
        }
    }

    @ViewBuilder
    private func planetButton(
        _ planet: OrbitPlanet, at point: CGPoint, metrics: OrbitMetrics
    ) -> some View {
        VStack(spacing: 2) {
            PlanetView(planet: planet,
                       diameter: metrics.diameter(for: planet),
                       isPending: model.pendingTransitions[planet.id] != nil)
                .matchedGeometryEffect(id: planet.id, in: cardNamespace)
            if metrics.showsPlanetLabels {
                Text(planet.issue.key)
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize()
            }
        }
        .position(point)
        .onTapGesture { selected = planet.id }
        .popover(isPresented: Binding(
            get: { selected == planet.id },
            set: { if !$0 { selected = nil } }
        )) {
            PlanetPopover(planet: planet, siteHost: model.siteHost)
                // 팝오버는 환경을 물려받지 않는다. 테마와 밀도를 **함께** 다시 넣어야
                // 안팎의 글자 크기가 같아진다 — `ArcadeFloorView`의 시트가 같은 이유로
                // 같은 두 줄을 갖고 있다.
                .environment(\.arcadeTheme, theme)
                .environment(\.arcadeMetrics, density)
        }
    }

    // MARK: - 제스처

    private func clampScale(_ value: Double, viewport: CGSize, extent: Double) -> Double {
        min(max(value, OrbitMetrics.minScale(viewport: viewport, extent: extent)),
            OrbitMetrics.maxScale(viewport: viewport, extent: extent))
    }

    private func pan(viewport: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { dragPan = $0.translation }
            .onEnded { value in
                committedPan = CGSize(width: committedPan.width + value.translation.width,
                                      height: committedPan.height + value.translation.height)
                dragPan = .zero
            }
    }

    private func magnify(viewport: CGSize, extent: Double) -> some Gesture {
        MagnifyGesture()
            .onChanged { gestureScale = $0.magnification }
            .onEnded { value in
                let base = scale ?? OrbitMetrics.fitScale(viewport: viewport, extent: extent)
                scale = clampScale(base * value.magnification,
                                   viewport: viewport, extent: extent)
                gestureScale = 1
            }
    }

    /// 트랙패드가 없거나 키보드만 쓰는 경우의 경로. 궤도가 유일한 경로인 정보는
    /// 없으므로(레인이 항상 있다) 접근성 하한은 "조작 가능"이다.
    private func zoomControls(viewport: CGSize, extent: Double) -> some View {
        HStack(spacing: density.tightGap) {
            Button("−") { step(0.8, viewport: viewport, extent: extent) }
                .keyboardShortcut("-", modifiers: .command)
            Button("＋") { step(1.25, viewport: viewport, extent: extent) }
                .keyboardShortcut("=", modifiers: .command)
            Button("전체") {
                scale = nil
                committedPan = .zero
            }
            .keyboardShortcut("0", modifiers: .command)
        }
        .arcadeType(.readout, .xs)
        .padding(density.rowGap)
    }

    private func step(_ factor: Double, viewport: CGSize, extent: Double) {
        let base = scale ?? OrbitMetrics.fitScale(viewport: viewport, extent: extent)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            scale = clampScale(base * factor, viewport: viewport, extent: extent)
        }
    }
}
```

- [ ] **Step 3: 빌드하고 색 리터럴 검사를 통과하는지 본다**

```bash
cd Packages/Jirarcade && swift build && swift test --filter ModuleBoundaryTests
```
Expected: 빌드 성공, 테스트 PASS

- [ ] **Step 4: 커밋한다**

```bash
git add Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/OrbitView.swift \
        Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/PlanetPopover.swift
git commit -m "feat: 상태별 태양계를 그리고 팬·줌을 붙인다"
```

---

### Task 7: 토글 — 레인과 궤도를 오간다

보드 상단에 보기 전환을 달고 궤도를 화면에 붙인다. 이 태스크가 끝나면 **처음으로 눈으로 확인할 수 있다.**

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/BoardViewMode.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/QuestBoardView.swift`

**Interfaces:**
- Consumes: `OrbitView` (Task 6)
- Produces: `enum BoardViewMode: String, CaseIterable { case lanes, orbit }`

- [ ] **Step 1: `BoardViewMode`를 만든다**

```swift
import SwiftUI

/// 퀘스트 보드가 같은 데이터를 보여주는 두 방식.
///
/// 세션 동안만 유지하고 저장하지 않는다 — 레인이 일하는 화면이고 궤도가 보는 화면이므로,
/// 앱을 다시 열었을 때 돌아갈 자리는 레인이다.
enum BoardViewMode: String, CaseIterable, Identifiable {
    case lanes, orbit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lanes: "≣ 레인"
        case .orbit: "◎ 궤도"
        }
    }
}
```

- [ ] **Step 2: `QuestBoardView`에 토글과 분기를 넣는다**

`@State` 선언 아래에 더한다:

```swift
    @State private var mode: BoardViewMode = .lanes
```

`body`를 통째로 아래로 바꾼다. 레인 쪽 내용은 **한 줄도 달라지지 않았고**, 달라진 것은 셋뿐이다: HUD 옆에 토글이 붙었고, 빈 상태가 모드 바깥으로 나왔고, 레인이 `case .lanes` 안으로 들어갔다.

```swift
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: metrics.sectionGap) {
                    BoardHUDView(model: model)
                    Picker("보기", selection: $mode) {
                        ForEach(BoardViewMode.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .padding(.trailing, metrics.gutter)
                }
                Divider().overlay(theme.line)

                // 티켓이 하나도 없으면 두 보기 모두 할 말이 같다. 빈 우주를 그리는 대신
                // 보드가 쓰던 안내를 그대로 쓴다.
                if model.issues.isEmpty {
                    ScrollView {
                        emptyState.padding(metrics.gutter)
                    }
                } else {
                    switch mode {
                    case .lanes:
                        lanes(width: geometry.size.width)
                    case .orbit:
                        OrbitView(model: model, cardNamespace: cardNamespace)
                    }
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.35),
                       value: model.pendingTransitions)
        }
        .background(theme.surfaceBase)
    }

    /// 레인 보기. 보드 스냅샷을 여기서 만드는 이유는 궤도 보기일 때 그 계산을
    /// 하지 않기 위해서다 — 순수 함수라 비싸지는 않지만, 쓰지 않는 좌표를 매 렌더마다
    /// 만들 이유도 없다.
    private func lanes(width: Double) -> some View {
        let board = BoardMetrics(
            availableWidth: max(width - metrics.gutter * 2, 200),
            metrics: metrics
        )
        let snapshot = model.boardSnapshot(minimumSpacing: board.minimumSpacing)

        return ScrollView {
            VStack(alignment: .leading, spacing: metrics.sectionGap) {
                ForEach(snapshot.lanes) { lane in
                    BoardLaneView(
                        lane: lane, axis: snapshot.axis, metrics: board,
                        model: model, cardNamespace: cardNamespace,
                        wipLimit: lane.stage == .active ? model.wipLimit : nil
                    )
                }
                if !snapshot.unmappedIssues.isEmpty {
                    UnmappedLaneView(issues: snapshot.unmappedIssues, model: model)
                }
            }
            .padding(metrics.gutter)
        }
    }
```

**주의:** 위 코드는 현재 `QuestBoardView.swift`의 `body`를 옮겨 적은 것이다. 실제 파일이 이와 다르면(다른 계획이 먼저 들어갔다면) **파일 쪽이 옳다** — 토글·빈 상태·모드 분기 셋만 반영하고 나머지는 그대로 둔다.

- [ ] **Step 3: 빌드하고 앱을 띄운다**

```bash
cd /Users/bahn/orca/workspaces/jirarcade/fix-improve-ui-ux
./scripts/make-app.sh --open
```

- [ ] **Step 4: 눈으로 확인한다**

`ArcadeUI`에는 테스트 타깃이 없으므로 여기부터가 검증이다. 하나씩 확인한다:

- [ ] 보드 상단 오른쪽에 `≣ 레인` / `◎ 궤도` 토글이 있다
- [ ] `◎ 궤도`를 누르면 태양계가 뜬다
- [ ] 기본 배율에서 태양이 **넷**이고, 보드 레인과 같은 순서(좌상 해야 할 일, 우상 진행 중, 좌하 개발 대기, 우하 모니터링)로 놓인다
- [ ] 트랙패드로 확대하면 `진행 중` 자리에서 태양이 여럿으로 **갈라진다**
- [ ] 갈라진 태양의 이름이 실제 Jira 상태명이다 (DEV 반영·STAG 병합 대기 등)
- [ ] 오래 묶인 티켓이 태양에서 **멀리** 있다
- [ ] 행성을 누르면 팝오버가 뜨고, 정체일이 카드와 **같은 값**이다
- [ ] `⌘0`으로 전체가 보이는 배율로 돌아온다
- [ ] 라이트/다크를 바꿔도 태양·궤도선·행성이 모두 읽힌다
- [ ] `≣ 레인`으로 돌아가면 보드가 그대로다

- [ ] **Step 5: 전체 테스트를 돌린다**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS

- [ ] **Step 6: 커밋한다**

```bash
git add Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/BoardViewMode.swift \
        Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/QuestBoardView.swift
git commit -m "feat: 퀘스트 보드에서 레인과 궤도를 오간다"
```

---

### Task 8: 연출 — 전환과 사건

카드가 행성으로 이어지게 하고, 티켓이 상태를 옮길 때 실제로 날아가게 한다. 이 태스크가 이 화면을 연출로 만든다(스펙 §1.1·§7).

**Files:**
- Modify: `Packages/Jirarcade/Sources/ArcadeCore/Board/OrbitLayout.swift` (extension 추가)
- Modify: `Packages/Jirarcade/Tests/ArcadeCoreTests/OrbitLayoutTests.swift` (추가)
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/OrbitView.swift`
- Modify: `Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/QuestBoardView.swift`

**Interfaces:**
- Produces: `public extension OrbitSnapshot { var membershipSignature: String { get } }`

**왜 서명이 필요한가:** 애니메이션 트리거로 `OrbitSnapshot` 전체를 쓰면 **줌할 때마다** 애니메이션이 걸린다. 태양 중심이 `zoomProgress`에 따라 움직이기 때문이다. 그러면 확대가 스프링을 타고 늦게 따라와 손가락과 화면이 어긋난다. 움직임이 붙어야 하는 것은 "어느 행성이 어느 태양에 어떤 등급으로 있는가"의 변화뿐이다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`OrbitLayoutTests.swift` 끝에 덧붙인다:

```swift
// MARK: - 애니메이션 트리거

/// 줌은 소속을 바꾸지 않는다. 서명이 줌에 반응하면 확대할 때마다 스프링이 걸려
/// 손가락과 화면이 어긋난다.
@Test func keepsTheMembershipSignatureStableAcrossZoom() {
    let issues = [issue(key: "DEMO-1", status: "Dev")]

    #expect(snapshot(issues, zoom: 0).membershipSignature
            == snapshot(issues, zoom: 1).membershipSignature)
}

/// 티켓이 상태를 옮기면 서명이 바뀐다 — 이때 행성이 날아가야 한다.
@Test func changesTheSignatureWhenAnIssueMovesStatus() {
    let before = snapshot([issue(key: "DEMO-1", status: "Dev")])
    let after = snapshot([issue(key: "DEMO-1", status: "Staging")])

    #expect(before.membershipSignature != after.membershipSignature)
}

/// 정체 등급이 오르면 궤도가 밀려나야 하므로 이것도 사건이다.
@Test func changesTheSignatureWhenATierRises() {
    let fresh = snapshot([issue(key: "DEMO-1", status: "Dev", updated: now)])
    let boss = snapshot([issue(key: "DEMO-1", status: "Dev",
                               updated: now.addingTimeInterval(-days(30)))])

    #expect(fresh.membershipSignature != boss.membershipSignature)
}

/// 티켓이 나타나고 사라지는 것도 사건이다.
@Test func changesTheSignatureWhenAnIssueAppears() {
    let one = snapshot([issue(key: "DEMO-1", status: "Dev")])
    let two = snapshot([issue(key: "DEMO-1", status: "Dev"),
                        issue(key: "DEMO-2", status: "Dev")])

    #expect(one.membershipSignature != two.membershipSignature)
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run: `cd Packages/Jirarcade && swift test --filter OrbitLayoutTests`
Expected: 컴파일 실패 — `value of type 'OrbitSnapshot' has no member 'membershipSignature'`

- [ ] **Step 3: 서명을 더한다**

`OrbitLayout.swift` 끝에 덧붙인다:

```swift
public extension OrbitSnapshot {
    /// 화면이 움직여야 할 **사건**만 담은 서명.
    ///
    /// 어느 행성이 어느 태양에 어떤 등급으로 있는가. 줌은 소속을 바꾸지 않으므로
    /// 여기 들어오지 않는다 — 스냅샷 전체를 애니메이션 트리거로 쓰면 확대할 때마다
    /// 스프링이 걸려 손가락과 화면이 어긋난다.
    var membershipSignature: String {
        let inSystems = systems.flatMap { system in
            system.planets.map { "\(system.statusName)/\($0.id)/\($0.tier.rawValue)" }
        }
        let adrift = drifters.map { "~/\($0.id)/\($0.tier.rawValue)" }
        return (inSystems + adrift).joined(separator: ",")
    }
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `cd Packages/Jirarcade && swift test --filter OrbitLayoutTests`
Expected: PASS (25개)

- [ ] **Step 5: 사건 연출을 붙인다**

`OrbitView.swift`의 `ZStack { ... }` 뒤, `.frame(...)` 앞에 더한다:

```swift
            .animation(reduceMotion ? nil : .spring(duration: 0.6),
                       value: snapshot.membershipSignature)
```

그리고 `planetButton`의 `VStack`에 등장·소멸 연출을 더한다. `.position(point)` **앞**에 넣는다:

```swift
        .transition(.opacity.combined(with: .scale(scale: 0.3)))
```

- [ ] **Step 6: 모드 전환 연출을 붙인다**

`QuestBoardView.swift`의 모드 분기를 감싼다. `switch mode { ... }` 전체를 다음으로 바꾼다:

```swift
                    Group {
                        switch mode {
                        case .lanes:
                            lanes(width: geometry.size.width)
                        case .orbit:
                            OrbitView(model: model, cardNamespace: cardNamespace)
                        }
                    }
                    // 카드와 행성이 같은 `cardNamespace`를 쓰므로, 모드가 바뀔 때
                    // 이 애니메이션이 둘을 이어 준다 — 카드가 사라지고 행성이 나타나는
                    // 것이 아니라 카드가 행성으로 접힌다.
                    .animation(reduceMotion ? nil : .spring(duration: 0.45), value: mode)
```

`Group`으로 감싸는 이유: `switch`는 뷰가 아니라 문(statement)이라 그 자체에 수식어를 붙일 수 없다.

- [ ] **Step 7: 빌드하고 눈으로 확인한다**

```bash
cd /Users/bahn/orca/workspaces/jirarcade/fix-improve-ui-ux
./scripts/make-app.sh --open
```

- [ ] 토글을 누르면 카드가 행성으로 **이어져** 보인다 (사라졌다 나타나지 않는다)
- [ ] 궤도에서 확대·축소할 때 태양 이동이 손가락을 **바로** 따라온다 (스프링이 끼지 않는다)
- [ ] 카드에서 상태를 옮기면(레인으로 돌아가 전이 실행 후 궤도로) 행성이 새 태양으로 날아간다
- [ ] 시스템 설정 → 손쉬운 사용 → 디스플레이 → **동작 줄이기**를 켜면 모든 연출이 꺼지고 좌표만 즉시 반영된다
- [ ] raid 등급 행성의 맥동도 동작 줄이기에서 멈춘다

- [ ] **Step 8: 전체 테스트를 돌린다**

Run: `cd Packages/Jirarcade && swift test`
Expected: PASS

- [ ] **Step 9: 커밋한다**

```bash
git add Packages/Jirarcade/Sources/ArcadeCore/Board/OrbitLayout.swift \
        Packages/Jirarcade/Tests/ArcadeCoreTests/OrbitLayoutTests.swift \
        Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/OrbitView.swift \
        Packages/Jirarcade/Sources/ArcadeUI/QuestBoard/QuestBoardView.swift
git commit -m "feat: 카드를 행성으로 잇고 사건이 있을 때만 움직인다"
```

---

### Task 9: 완성 정의 확인과 문서 갱신

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/records/2026-08-21-quest-board-visual-checklist.md`

- [ ] **Step 1: 스펙 §16의 완성 정의를 하나씩 확인한다**

앱을 띄운 채로 확인하고, 통과하지 못한 항목이 있으면 **여기서 멈추고 고친다.**

- [ ] 토글로 레인 ↔ 궤도를 오갈 수 있고, 전환에서 카드가 행성으로 이어진다
- [ ] 줌아웃에서 태양 4개, 줌인에서 실제 상태로 갈라진다. 태양이 생기거나 사라지지 않는다
- [ ] `active`를 줌인하면 여덟 개 상태가 각각의 태양으로 보인다
- [ ] 동기화를 여러 번 해도(⌘R 또는 5분 대기) 행성 위치가 흔들리지 않는다
- [ ] 상태를 옮기면 행성이 새 태양으로 날아간다
- [ ] 동작 줄이기에서 모든 연출이 꺼지고 좌표만 반영된다
- [ ] 미매핑 티켓이 바깥 고리에 떠돌이로 보인다
- [ ] `swift test` 전부 통과
- [ ] 라이트/다크 모두에서 읽힌다

- [ ] **Step 2: 시각 검증 체크리스트에 궤도 항목을 더한다**

`docs/superpowers/records/2026-08-21-quest-board-visual-checklist.md` 끝에 절을 더한다:

```markdown
## 궤도 뷰 (계획 2b-4)

테스트로 검증할 수 없는 것만 적는다. 좌표의 옳음은 `OrbitLayoutTests`가 이미 본다.

- [ ] `≣ 레인` → `◎ 궤도` 전환에서 카드가 행성으로 **이어진다**. 사라졌다 나타나면 실패다
- [ ] 확대·축소 중 태양 이동이 손가락을 바로 따라온다. 스프링이 끼면 서명(§membershipSignature)이 줌에 반응하는 것이다
- [ ] 줌 경계에서 태양이 깜빡이거나 사라지지 않는다 — 갈라질 뿐이다
- [ ] 상태를 옮기면 행성이 옛 태양에서 새 태양으로 날아간다
- [ ] 동작 줄이기를 켜면 전환·비행·맥동이 모두 멈추고 좌표만 즉시 반영된다
- [ ] 라이트 테마에서 궤도선(`line`)이 배경에 묻히지 않는다
- [ ] 다크 테마에서 raid 행성의 채움(`boss`)이 태양(`accent`)과 구분된다
- [ ] 행성 팝오버의 정체일이 같은 티켓의 카드와 **같은 값**이다(근사 `~` 포함)
```

- [ ] **Step 3: README를 갱신한다**

"동작합니다" 목록에 한 줄 더한다:

```markdown
- 궤도 보기 — 상태 하나가 태양이 되고 티켓이 정체일만큼 떨어진 궤도에 놓인다. 확대하면 단계 안에 접혀 있던 실제 상태들이 갈라진다
```

문서 표에 한 줄 더한다:

```markdown
| [궤도 뷰 설계](docs/superpowers/specs/2026-08-24-orbit-view-design.md) | 태양계 문법·계층 줌·좌표 계산·연출 경계 |
```

"아직 없습니다" 목록의 `CRT 연출·레벨업 애니메이션`은 **그대로 둔다** — 이 계획이 그것을 만들지 않았다.

- [ ] **Step 4: 커밋한다**

```bash
git add README.md docs/superpowers/records/2026-08-21-quest-board-visual-checklist.md
git commit -m "docs: 궤도 보기를 스코프와 시각 검증 목록에 적는다"
```

---

## 완성 확인

전부 끝나면 다음이 참이어야 한다.

- [ ] `swift test` 전부 통과 (기존 532개 + 궤도 42개)
- [ ] `ModuleBoundaryTests` 셋 모두 통과 — SwiftUI 경계·색 리터럴·조직명
- [ ] `Sources/ArcadeUI/` 아래 `Date()`·`Calendar.current`·`RuleSet.default` 출현 횟수가 **여전히 0**
  ```bash
  grep -rn "Date()\|Calendar.current\|RuleSet.default" Packages/Jirarcade/Sources/ArcadeUI/ | wc -l
  ```
- [ ] 채점 관련 파일에 변경이 없다
  ```bash
  git diff --stat main -- Packages/Jirarcade/Sources/ArcadeCore/Rules/ \
                          Packages/Jirarcade/Sources/ArcadeCore/Sync/ \
                          Packages/Jirarcade/Sources/ArcadeCore/Store/
  ```
  Expected: 빈 출력
- [ ] 스펙 §16 완성 정의의 아홉 항목을 눈으로 확인했다

## 다음 계획

이 계획이 열어 두고 간 것들이다. **지금 하지 않는다.**

- **태양 간 연결선** — 이벤트 로그에 전이 이력이 있으므로 "어느 경로로 몇 번 갔는가"를 선으로 그릴 수 있다. 다만 선이 들어오면 이 화면의 성격이 연출에서 다이어그램으로 바뀌므로 별도 스펙이 필요하다
- **궤도에서 상태 전이** — 행성을 다른 태양으로 끌어다 놓기. 궤도를 며칠 써 본 뒤 판단한다
- **보류 상태 폴백 확인** — 스펙 부록 A. `"보류": "done"` 폴백 때문에 보류 티켓이 완료로 채점되고 마감 보너스까지 받고 있을 수 있다. 궤도와 무관한 별개 사안이다
