# Jirarcade 앱 셸 설계 (계획 2a)

- 작성일: 2026-08-14
- 상태: 확정 (구현 계획 작성 대기)
- 선행: `docs/superpowers/specs/2026-08-12-jirarcade-design.md` (v0.1 전체 설계)
- 대상 플랫폼: macOS 26+ / Swift 6.2 / SwiftUI

---

## 1. 배경과 범위

v0.1의 기반 계층(규칙 엔진·Jira 클라이언트·영속화)은 완성됐다. 156개 테스트가 UI 없이 통과하며,
`SyncEngine.sync(jql:now:)` 한 번이면 페치 → diff → 저장 → 재집계가 전부 일어난다.

남은 것은 사람이 볼 수 있는 부분이다. 그런데 v0.1 스펙 §10의 UI 항목을 한 계획에 묶으면
계획 1과 비슷하거나 더 큰 규모가 되고, **SwiftUI를 처음 만나는 구간이 길어진다.** 그래서 둘로 나눈다.

| | 범위 | 완성 시 |
|---|---|---|
| **2a** (이 문서) | 앱 타깃 · 테마 · 온보딩 · 동기화 스케줄러 · 아케이드 플로어 셸 | 로그인하면 동기화가 돌고 플로어가 뜬다 |
| **2b** | 퀘스트 보드 · 티켓 상세/전이 · 팀 판 · 설정 | 매일 쓸 수 있는 앱 |

2a에 테마를 넣고 퀘스트 보드를 뺀 것은 의도적이다. 테마는 모든 화면이 의존하는 기반이라
나중에 넣으면 이미 만든 화면을 전부 손봐야 한다. 반면 퀘스트 보드는 셸 위에 얹히는 캐비닛 하나라
나중에 붙여도 셸을 건드리지 않는다 — v0.1 스펙 §3.1의 `Cabinet` 프로토콜이 그 경계다.

**2a가 끝나면 "동작하지만 볼 게 적은 앱"이 된다.** 로그인되고, 5분마다 동기화가 돌고, 이벤트가 쌓인다.
심심해 보이지만 이때부터 XP가 실제로 쌓이므로, 2b에서 퀘스트 보드를 만들 때 이미 며칠치 실데이터가 있다.

### 1.1 이 계획에서 새로 설계하는 것

v0.1 스펙에 이미 있는 것(테마 팔레트 §6, 화면 구성 §7, 인증 수명주기 §8)은 여기서 반복하지 않고 참조한다.
새로 결정해야 했던 것은 셋이다:

- **워크플로 매핑 온보딩** — 조직 정보를 앱에 내장하지 않기로 하면서 생겼다. 사용자가 첫 실행 때 지정한다.
- **동기화 스케줄러** — 기반 계층은 `sync()` 호출만 제공한다. 언제 부를지는 앱의 몫이다.
- **앱 상태 모델** — 인증 상태 머신(§8.1)에 매핑 단계를 더한 형태.

---

## 2. 모듈 구조

```
JirarcadeApp/                    @main · 윈도우 · AppModel 생성   (로직 없음)
Packages/Jirarcade/Sources/
  ├── JiraKit/                   (계획 1) HTTP · 인증 · DTO · 클라이언트
  ├── ArcadeCore/                (계획 1) 규칙 · 동기화 · 저장소
  ├── ArcadeApp/    ← 신규       AppModel · 인증 상태 머신 · CredentialStore · SyncScheduler
  └── ArcadeUI/     ← 신규       테마 · Cabinet 프로토콜 · 셸 · 온보딩 화면
```

의존은 단방향이다: `ArcadeUI → ArcadeApp → ArcadeCore → JiraKit`

| 모듈 | 지키는 규칙 |
|---|---|
| `ArcadeApp` | **SwiftUI를 import하지 않는다.** 이 모듈의 테스트는 화면 없이 빠르게 돈다. |
| `ArcadeUI` | 상태를 만들지 않는다. `ArcadeApp`이 소유한 것을 읽어 그리고, 입력을 되돌려준다. |

`ArcadeApp`이 SwiftUI를 모른다는 제약이 이 계획의 중심 장치다. 계획 1에서 `Rules/`가 SwiftData를 모르게 한 것과
같은 종류이며, 컴파일러가 강제하므로 시간이 지나도 침식되지 않는다. 실질적 효과는 한 가지 질문에 답할 수 있다는 것이다 —
*"이 파일에 SwiftUI가 있나?"* 있으면 테스트하지 않고 눈으로 확인하고, 없으면 테스트가 있어야 한다.

**앱 타깃을 얇게 두는 이유**는 계획 1과 같다. 앱 타깃 테스트는 호스트 앱을 띄워야 해서 느리고, 결국 아무도 쓰지 않는다.
로직이 SPM 모듈에 있으면 `swift test`로 계속 검증된다.

---

## 3. 앱 상태 모델

`AppModel`이 앱 전체 상태를 소유한다. `@Observable` 클래스 하나이며 `@MainActor`에 격리된다.

```swift
@Observable @MainActor
public final class AppModel {
    public private(set) var phase: Phase
    public private(set) var summary: PlayerSummary?
    public private(set) var lastSync: SyncRunSummary?
    public private(set) var observationDays: Int
    public private(set) var unmappedStatuses: [String]
    public var appearancePreference: AppearancePreference

    public enum Phase: Equatable {
        case launching                              // Keychain 확인 중
        case signedOut(message: String?)            // 로그인 화면
        case validating                             // /myself 확인 중
        case mappingWorkflow(candidates: [String])  // 매핑 마법사
        case ready                                  // 플로어
        case expired                                // 읽기 전용 + 재인증 배너
    }
}
```

v0.1 스펙 §8.1의 상태 머신에 **`mappingWorkflow`가 하나 추가**된 형태다. 매핑이 없으면 모든 전이가 0점이라
앱이 무의미하므로 `ready`로 가는 길목에 둔다.

`@Observable`은 Swift 5.9의 Observation 프레임워크다. 기존 `ObservableObject` + `@Published`와 달리
프로퍼티마다 표시가 필요 없고, SwiftUI가 실제로 읽은 프로퍼티만 추적해 불필요한 갱신이 줄어든다.

**의존성은 생성자로 주입한다.**

```swift
public init(
    store: ArcadeStore,
    credentials: any CredentialStore,
    clientFactory: @escaping (any AuthProvider) -> JiraClient,
    clock: @escaping () -> Date,
    calendar: Calendar
)
```

계획 1 내내 지킨 "시간은 파라미터로" 규칙을 앱 계층까지 잇는다. 테스트가 "5분 뒤"를 시뮬레이션하려면 `clock`을 바꾸면 된다.
`clientFactory`는 자격증명이 정해진 뒤에야 `JiraClient`를 만들 수 있기 때문에 필요하다.

`AppearancePreference`(`.system` / `.light` / `.dark`)는 `ArcadeApp`에 정의한다 — 값은 `UserDefaults`에 저장되고
`ArcadeUI`가 읽어 테마를 고르지만, SwiftUI 타입이 아니므로 UI 모듈에 둘 이유가 없다.

---

## 4. 온보딩 흐름

```
앱 실행
  │
  ├─ Keychain에 자격증명 있음 ──▶ validating ──▶ 매핑 있음? ──▶ ready
  │                                    │              └ 없음 ──▶ mappingWorkflow
  │                                    └─ 401 ──▶ expired
  └─ 없음 ──▶ signedOut
```

### 4.1 로그인

사이트 주소 · 이메일 · API 토큰 3개를 받는다. 토큰 발급 페이지
(`https://id.atlassian.com/manage-profile/security/api-tokens`) 링크 버튼을 둔다 — 처음 쓰는 사람은
"API 토큰"이 무엇인지 모르므로 화면에서 바로 갈 수 있어야 한다.

검증은 두 단계다:

```swift
let auth = try APITokenAuth(site: site, email: email, token: token)   // throws → 잘못된 주소
let user = try await client.myself()                                   // 401 → 잘못된 자격증명
```

첫 줄이 던지면 "사이트 주소를 확인해 주세요"(`JiraError.invalidSite`), 둘째 줄이 401이면
"이메일 또는 토큰이 올바르지 않습니다". **에러 메시지에 토큰·이메일을 넣지 않는다** — 전역 제약이 UI까지 이어진다.

성공하면 Keychain에 저장하고 매핑 단계로 간다.

### 4.2 매핑 마법사

이 계획에서 새로 설계하는 유일한 화면이다.

```
┌─ 워크플로 매핑 ─────────────────────────────────┐
│ 이 Jira의 상태를 게임 단계에 연결해 주세요.      │
│ 나중에 설정에서 바꿀 수 있습니다.                │
│                                                │
│  To Do          [ 대기      ▾ ]                │
│  In Progress    [ 진행      ▾ ]                │
│  In Review      [ 검토      ▾ ]                │
│  Verifying      [ 확인      ▾ ]                │
│  Done           [ 완료      ▾ ]                │
│                                                │
│  ⓘ 상태 5개를 내 티켓 47건에서 찾았습니다        │
│                              [ 시작하기 ]       │
└────────────────────────────────────────────────┘
```

**상태 후보는 온보딩 조회 한 번에서 얻는다.**

```swift
let probe = try await source.fetchAssignedIssues(
    jql: "assignee = currentUser() AND statusCategory != Done"
)
let candidates = Set(probe.issues.map(\.statusName)).sorted()
```

Jira의 전역 상태 목록(`/rest/api/3/status`)을 쓰지 않는 이유는 조직 전체 상태가 수십 개 나올 수 있고,
그중 대부분은 내 티켓에 등장하지 않기 때문이다. 실제로 쓰이는 것만 매핑하면 목록이 짧아 클릭 몇 번이면 끝난다.
새 상태가 나중에 나타나면 `WorkflowMap.unmappedStatuses(in:)`가 잡아 설정에서 추가한다.

**이 조회는 미러에 저장하지 않는다.** 매핑이 정해지기 전에 이벤트를 만들면 그 이벤트가 0점으로 굳는다.
이벤트 로그는 append-only라 나중에 재집계해도 복구되지 않는다. 매핑 완료 후 정식 동기화가 처음부터 다시 돈다.

**매핑은 강제하지 않는다.** 일부 상태를 비워둬도 "시작하기"가 활성화된다. 조직에 없는 단계를 억지로 채우게 하는 것보다
낫고, 사용자가 "이 상태는 우리가 안 쓴다"고 판단할 수 있어야 한다. 대신:

- 미매핑 상태가 있으면 확인 문구를 보여준다: *"상태 2개가 매핑되지 않았습니다. 해당 티켓의 전이는 점수에 반영되지 않습니다."*
- 플로어 마퀴에 **지속적으로** 배지가 뜬다 (§7). 강제하지 않는 대신 잊히지 않게 한다.

드롭다운 라벨은 `Stage`의 한국어 표시명이다: `backlog`→대기, `active`→진행, `review`→검토, `verify`→확인, `done`→완료.

### 4.3 저장

| 항목 | 위치 | 이유 |
|---|---|---|
| 사이트 주소 · 이메일 · 토큰 | **Keychain** | 자격증명. 앱 DB는 평문이며 백업에 딸려 나간다 |
| 워크플로 매핑 | `~/Library/Application Support/Jirarcade/workflow.json` | 조직 정보이지만 자격증명은 아니다 |
| 외관 설정 · 동기화 주기 | `UserDefaults` | 민감하지 않은 앱 설정 |

매핑을 파일로 두는 이유는 사용자가 직접 열어 고칠 수 있어야 하기 때문이다 — 설정 화면이 생기기 전(2b)에도
매핑을 바꿀 방법이 있어야 한다.

**저장 위치는 앱 지원 디렉터리이지 프로젝트 디렉터리가 아니다.** 저장소의 `.gitignore`에 있는 `.jirarcade/`와
`*.local.json`은 개발 중 실수로 프로젝트 루트에 설정 파일을 만드는 경우를 막는 안전망이며,
정상 경로는 `FileManager.default.url(for: .applicationSupportDirectory, ...)` 아래다.

**다른 계정으로 로그인하면 미러와 이벤트 로그를 초기화한다**(v0.1 스펙 §8.2). 남의 XP와 내 XP가 섞이면 복구할 수 없다.

---

## 5. 동기화 스케줄러

`SyncScheduler`는 `ArcadeApp`에 두는 UI 없는 타입이다. 세 가지 계기로 동기화가 돈다.

| 계기 | 동작 |
|---|---|
| 주기 | 기본 5분 (`UserDefaults`에서 읽는다 — 게임 규칙이 아니라 앱 설정이므로 `RuleSet`이 아니다) |
| 창 활성화 | 포그라운드 진입 시 즉시. 단 **마지막 동기화가 30초 이내면 건너뛴다** |
| 수동 | 사용자가 새로고침 |

### 5.1 중복 실행 방지

5분 타이머가 도는 동안 사용자가 창을 전환하면 두 동기화가 겹칠 수 있고, 그러면 같은 diff가 두 번 계산되어
**이벤트가 중복된다.** `isSyncing` 플래그로 막는다. `@MainActor` 격리 덕에 원자성은 자동으로 보장된다.

```swift
@MainActor
public final class SyncScheduler {
    private var isSyncing = false

    public func requestSync(reason: Reason) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        ...
    }
    public enum Reason { case timer, foreground, manual }
}
```

### 5.2 백오프

v0.1 스펙 §8.4의 `5초 → 30초 → 2분 → 10분(상한)`을 여기서 구현한다. 연속 실패 횟수를 세다가 성공하면 초기화하고,
**3회 연속 실패해야 UI에 표시한다.** 일시적 끊김마다 경고를 띄우면 사용자는 경고를 무시하는 법부터 배운다.

**`rateLimited`는 특별 취급한다** — `retryAfter`를 그대로 존중하고 백오프 카운터를 올리지 않는다.
속도 제한은 장애가 아니라 정상 동작이다.

### 5.3 타이머 구현

`Timer`가 아니라 `Task`로 만든다.

```swift
private func loop() async {
    while !Task.isCancelled {
        try? await sleep(.seconds(interval))
        await requestSync(reason: .timer)
    }
}
```

`Timer`는 런루프에 묶여 있어 `async` 코드와 섞기 번거롭고 취소가 지저분하다. `Task`는 `cancel()` 한 번이면 정리되고
`@MainActor` 격리도 자연스럽게 따라온다.

**대기는 주입한다.** 스케줄러가 `Task.sleep`을 직접 부르면 테스트가 5분을 기다려야 한다.

```swift
public init(sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
```

테스트는 즉시 반환하는 `sleep`을 넣어 "5분이 세 번 지났다"를 밀리초에 시뮬레이션한다.
계획 1에서 `now: Date`를 주입한 것과 같은 수법이다.

---

## 6. 테마 구현

계획 1의 `PaletteTokens`가 hex와 WCAG 대비 검증까지 끝내뒀다. 여기서는 `Color`로 바꿔 SwiftUI에 흘려보낸다.

```swift
public struct ArcadeTheme: Sendable {
    public let surfaceBase, surfaceRaised, line: Color
    public let inkPrimary, inkSecondary, inkTertiary: Color
    public let accent, boss, danger, good: Color
    public let usesGlow: Bool        // dark: true  / light: false
    public let usesHalftone: Bool    // dark: false / light: true

    public static func make(_ appearance: PaletteTokens.Appearance) -> ArcadeTheme
}
```

`make(_:)`가 `PaletteTokens.hex(_:in:)`을 읽어 변환한다. **hex는 한 곳에만 있고 검증도 한 곳에서만** 된다 —
계획 1의 대비 테스트가 그대로 이 값들을 지킨다.

**뷰 코드에 색 리터럴을 두지 않는다.** 전부 `@Environment(\.arcadeTheme)`로 접근한다.
리터럴이 하나라도 남으면 그 지점이 반대 테마에서 깨지므로 리뷰 항목으로 못박는다.

**외관 결정** — 시스템 따름(기본) · 라이트 · 다크 3택. `.system`일 때는 `@Environment(\.colorScheme)`을 따라가고,
나머지는 그것을 무시한다. 루트 뷰가 둘을 합쳐 `ArcadeTheme`를 만들어 환경에 주입하면
아래 모든 뷰는 아무것도 모른 채 올바른 색을 받는다.

**효과는 2a에서 최소로 한다.** `usesGlow`/`usesHalftone` 플래그는 정의하되, CRT 스캔라인·Metal 셰이더 같은 연출은
2b로 미룬다. 2a에는 그걸 입힐 화면이 거의 없고, 셰이더는 실패해도 조용해서 디버깅이 까다롭다.
2a는 색과 타이포만 맞춘다.

---

## 7. 셸과 관측 캐비닛

```
▨ ARCADE FLOOR ▨  ── 3 CREDITS ──  ⚠ 매핑되지 않은 상태 2개
┌──────────┐ ┌──────────┐ ┌──────────┐
│OBSERVATION│ │  COMING  │ │  COMING  │
│          │ │   SOON   │ │   SOON   │
│ 관측 3일차 │ │          │ │          │
│ 티켓 47   │ │          │ │          │
│ 이벤트 128 │ │          │ │          │
│ LV.4 620XP│ │          │ │          │
│  ▶ OPEN  │ │          │ │          │
└──────────┘ └──────────┘ └──────────┘
마지막 동기화 2분 전 · 다음 3분 후          [ 새로고침 ]
```

셸은 `Cabinet` 프로토콜만 안다(v0.1 스펙 §3.1). 2a에는 구현체가 `ObservationCabinet` 하나뿐이고,
2b에서 `QuestBoardCabinet`이 **셸을 건드리지 않고** 추가된다.

**관측 캐비닛이 보여주는 것은 전부 계획 1의 API로 얻는다:**

| 표시 | 출처 |
|---|---|
| 관측 N일차 | `ArcadeStore.observationDayCount(now:calendar:)` |
| 미완료 티켓 수 | `ArcadeStore.loadMirror().count` |
| 누적 이벤트 수 | `ArcadeStore.loadEvents().count` |
| 레벨 · XP | `SyncOutcome.summary` (`PlayerSummary`) |
| 마지막 동기화 · 메모 | `SyncRunSummary` (`note` — 파싱 실패가 여기 뜬다) |

**이 캐비닛은 2b에서도 남는다.** 디버깅 창으로 계속 쓸모가 있고, "앱이 지금 무엇을 알고 있는가"를 보여주는
유일한 화면이다.

**마퀴의 경고 배지** — 미매핑 상태가 있으면 여기 뜬다. 매핑을 강제하지 않기로 했으니
지속적으로 보이는 자리가 필요하다. 누르면 매핑 마법사를 다시 연다(2b에서 설정 화면이 생기면 그리로 간다).

---

## 8. 에러 처리

v0.1 스펙 §8.4의 분류를 그대로 따른다. UI에서 달라지는 것은 "어디에 어떻게 보이느냐"뿐이다.

| 상태 | 표시 |
|---|---|
| `expired` | 상단 고정 배너 "다시 로그인해 주세요" + **미러는 그대로 보임** |
| `offline` | 상태바 "오프라인 · 마지막 동기화 12분 전" |
| 3회 연속 실패 | 상태바 "Jira에 연결하지 못했습니다" + 재시도 버튼 |
| `rateLimited` | **표시 없음.** 조용히 대기 후 재시도 |
| 파싱 실패 | 관측 캐비닛의 메모 줄 (`SyncRunSummary.note`) |

**핵심은 `expired`가 읽기를 막지 않는다는 것이다.** 인증 실패는 쓰기 불가이지 읽기 불가가 아니다.
`Phase.expired`가 이것을 타입으로 보장한다 — `signedOut`과 달리 미러를 지우지 않는다.

---

## 9. 테스트 전략

```
ArcadeUI (SwiftUI)     자동화하지 않음. 눈으로 확인.
ArcadeApp              이 계획 테스트의 대부분
```

계획 1 스펙 §9의 원칙을 그대로 잇는다. SwiftUI 화면 테스트를 빼는 것은 의도적이다 —
XCUITest는 느리고 잘 깨지는데, 이 계획에서 틀릴 수 있는 것(상태 전이·스케줄 판정·자격증명 수명)은
전부 화면 아래에 있다.

**`ArcadeApp`에서 테스트할 것:**

| 영역 | 케이스 |
|---|---|
| 인증 상태 머신 | 각 전이가 올바른 `Phase`로 가는가. 특히 **401이 `signedOut`이 아니라 `expired`로** 가는가 |
| 매핑 온보딩 | 조회 결과에서 상태 후보를 뽑는 로직 / 부분 매핑 시 `unmappedStatuses`가 정확한가 / 매핑 전 조회가 미러를 건드리지 않는가 |
| `SyncScheduler` | 동시 요청이 하나로 합쳐지는가 / 30초 쿨다운이 창 활성화를 건너뛰는가 / 백오프가 5→30→120→600으로 늘고 성공 시 초기화되는가 / `rateLimited`가 백오프 카운터를 올리지 않는가 |
| `CredentialStore` | 저장·조회·삭제 / **다른 계정으로 로그인하면 미러가 초기화되는가** |

`CredentialStore`는 실제 Keychain을 건드리므로 **프로토콜로 추상화하고 테스트는 인메모리 구현을 쓴다.**
계획 1의 `HTTPClient`·`IssueSource`와 같은 수법이다.

---

## 10. 스코프 경계

### 포함

1. 앱 타깃 (`@main` · 윈도우 · `AppModel` 생성)
2. `ArcadeApp` 모듈 — `AppModel` · 인증 상태 머신 · `CredentialStore` · `SyncScheduler`
3. `ArcadeUI` 모듈 — `ArcadeTheme` · `Cabinet` 프로토콜 · 셸 · 온보딩 화면
4. 로그인 화면 + Keychain 저장 + `expired` 처리
5. 워크플로 매핑 마법사 + 파일 저장
6. 동기화 스케줄러 (주기 · 창 활성화 · 수동 · 백오프)
7. 아케이드 플로어 셸 + 관측 캐비닛 + `COMING SOON` 2칸
8. 테마 (색 · 타이포 · 시스템 외관 연동)
9. 오프라인 · 연결 실패 · 파싱 실패 표시

### 제외 (2b로)

| 제외 항목 | 이유 |
|---|---|
| 퀘스트 보드 캐비닛 | 2b의 본체. 셸이 완성돼야 얹을 수 있다 |
| 티켓 상세 시트 · 전이 실행 | 쓰기 경로. 5초 실행 취소 UX가 별도 설계를 요구한다 |
| 열람 이벤트 | 티켓 상세가 있어야 발생한다 |
| 팀 판 | 읽기 전용 화면. 퀘스트 보드와 데이터 소스를 공유한다 |
| 설정 화면 6종 | 2a에서는 매핑만 마법사로 처리한다 |
| CRT 연출 · 셰이더 · 레벨업 애니메이션 | 입힐 화면이 2a에 거의 없다 |

---

## 11. 완성 정의

아래가 모두 참이면 2a가 끝난 것이다.

```
□ 로그인 → 매핑 → 플로어까지 한 번에 통과된다
□ 앱을 껐다 켜면 로그인 없이 바로 플로어가 뜬다
□ 5분마다 동기화가 돌고 관측 캐비닛의 숫자가 늘어난다
□ 네트워크를 끊어도 앱이 열리고 마지막 상태를 보여준다
□ 시스템 외관을 라이트/다크로 바꾸면 색이 따라 바뀐다
□ 뷰 코드에 색 리터럴이 없다
□ ArcadeApp이 SwiftUI를 import하지 않는다
□ swift test 전부 통과 (계획 1의 156개 + ArcadeApp 신규)
□ swift build 경고 0
```

---

## 12. 리스크

| 리스크 | 완화책 |
|---|---|
| **SwiftUI 학습 곡선** — 계획 1은 순수 로직이었고 여기서 처음 화면을 만든다 | 로직(`ArcadeApp`)을 먼저 만들고 화면을 나중에 얹는다. 화면이 틀렸는지 로직이 틀렸는지 고민할 필요가 없다 |
| **Keychain API의 까다로움** — `SecItemAdd` 계열은 에러 코드가 불친절하다 | 프로토콜로 추상화해 테스트는 인메모리로 돈다. 실제 Keychain 경로는 수동 확인 |
| ~~**서명 없는 SPM 실행 파일에서 Keychain이 막힐 수 있다**~~ — 막히면 앱 타깃을 `.xcodeproj`로 바꿔야 했다 | **해소됨(2026-08-14).** 실제 라운드트립(저장→조회→삭제→조회)이 통과했고 `errSecMissingEntitlement`(-34018)는 나오지 않았다. macOS 15 / tools-version 6.2 환경에서 SPM이 실행 타깃에 `<타깃명>-entitlement.plist`를 자동 생성해 붙인다 |
| **`@Observable` + `@MainActor` 조합의 컴파일 에러** — 계획 1에서 Swift 6 동시성으로 세 번 막혔다 | 막히면 임의로 구조를 바꾸지 말고 보고한다. 리뷰어가 컴파일러로 재현해 판정한다 |
| **매핑 마법사가 첫 화면인데 가장 새로운 설계** | 상태 후보를 조회 한 번으로 얻는 방식이 실제 응답에서 동작하는지 초기에 확인한다 |

---

## 13. 결정 기록

| 결정 | 채택 | 기각한 대안 | 이유 |
|---|---|---|---|
| 계획 분할 | 2단계 (셸 → 알맹이) | 한 계획 / 3단계 | SwiftUI 첫 구간을 짧게 끊어 피드백을 빨리 받는다. 3단계는 계획·리뷰 사이클이 과하다 |
| 앱 로직 위치 | `ArcadeApp` 모듈 분리 | `ArcadeUI`에 통합 / 앱 타깃에 | "이 파일에 SwiftUI가 있나"로 테스트 여부가 갈리게 한다. 앱 타깃은 테스트가 느려 결국 안 쓰인다 |
| 매핑 시점 | 로그인 직후 필수 | 자동 추측 / 첫 동기화 후 안내 | 매핑 전 이벤트는 0점으로 굳고 재집계해도 복구되지 않는다. 한글·커스텀 상태명은 추측도 불가능하다 |
| 매핑 강제 | 하지 않음 (배지로 유도) | 5단계 전부 필수 | 조직에 없는 단계를 억지로 채우게 하는 것보다 낫다. 대신 마퀴 배지로 잊히지 않게 한다 |
| 상태 후보 출처 | 내 티켓 조회 1회 | 전역 상태 API | 조직 전체 상태는 수십 개가 나오고 대부분 쓰이지 않는다. 새 API도 필요 없다 |
| 플로어 내용 | 관측 캐비닛 1개 | 3칸 모두 COMING SOON / 상태 화면만 | 동기화가 실제로 도는지 눈으로 확인되고, 2b 개발 중 디버깅 창이 된다 |
| 창 활성화 쿨다운 | 30초 | 없음 / 더 길게 | 창을 자주 전환해도 API를 낭비하지 않으면서, 돌아왔을 때 최신 상태를 본다 |
| 타이머 | `Task` + 주입된 `sleep` | `Timer` | `async`와 섞기 쉽고 취소가 깨끗하다. 주입으로 5분 대기를 밀리초에 테스트한다 |
| 효과(셰이더) | 2b로 미룸 | 2a에서 함께 | 입힐 화면이 없고, 셰이더는 실패해도 조용해 디버깅이 어렵다 |
