# Jirarcade 설계 문서 (v0.1)

- 작성일: 2026-08-12
- 상태: 확정 (구현 계획 작성 대기)
- 대상 플랫폼: macOS 26+ / Swift 6.2 / SwiftUI
- 대상: Jira Cloud (사이트 주소·프로젝트·워크플로는 사용자가 설정에서 지정한다)

---

## 1. 배경과 목표

Atlassian Jira의 업무 데이터를 아케이드 게임의 언어로 다시 보여주는 macOS 데스크톱 앱을 만든다.
목적은 화면을 예쁘게 만드는 것이 아니라, **특정 업무 습관을 실제로 유도하는 것**이다.

유도 대상 습관 4가지(사용자 선택):

1. 정체된 티켓 깨우기
2. 상태를 제때 갱신하기
3. 매일 열어보는 습관
4. 마감 방어하기

### 1.1 설계 근거가 된 관측

설계 전 실제 Jira 인스턴스 한 곳을 조회해 아래를 관측했다. 조직을 특정하는 값은 이 문서에 남기지 않고,
설계에 영향을 준 **형태**만 기록한다. 이후 문서 전체에서 상태명은 일반적인 영문 예시를 쓴다.

| 항목 | 관측된 형태 |
|---|---|
| 미완료 티켓 규모 | 한 사람 기준 수십 건 |
| 상태 분포 | 특정 한 단계에 절반 가까이 고여 있음 (전체 50건 중 24건) |
| 워크플로 | 표준 3단계가 아닌 **5단계 커스텀**, 상태명도 조직 고유 |
| active 단계 티켓 수 | 12건 — WIP 한도(5)를 크게 초과 |
| `updated` 분포 | 24건이 이틀 안에 몰려 있음 (일괄 갱신 흔적) |

여기서 도출된 두 가지 제약:

- **표준 3단계(To Do / In Progress / Done)를 가정하면 안 된다.** 상태→단계 매핑은 설정으로 외부화한다.
- **`updated` 필드는 "정체" 지표로 신뢰할 수 없다.** 코멘트·라벨 수정으로도 갱신되며, 실제로 일괄 갱신 흔적이 있다. 정체 판정은 별도 설계가 필요하다(§5.2).

---

## 2. 확정된 제품 방향

컨셉 4종(퀘스트 대시보드 / 슈팅 게임 / CRT 터미널 / 아케이드 플로어)을 목업으로 비교한 결과:

> **아케이드 플로어(D)를 셸로 삼고, 퀘스트 대시보드(A)를 1호 캐비닛으로 구현한다.**

- 셸을 1일차에 만드는 이유: 나중에 캐비닛을 추가할 때 기존 캐비닛의 내장을 뜯지 않기 위해서다.
- 캐비닛을 1개만 넣는 이유: 3개를 동시에 시작하면 전부 미완성이 된다.
- 슈팅 게임(B)을 1차에서 빼는 이유는 재미가 부족해서가 아니라, 게임 루프에 4~6주를 쓰는 동안 인증·동기화·워크플로 매핑이라는 기반이 검증되지 않은 채 남기 때문이다.

---

## 3. 아키텍처와 모듈 경계

```
JirarcadeApp/                 얇은 앱 타깃 (진입점 + 윈도우. 로직 없음)
Packages/Jirarcade/Sources/
  ├── JiraKit/                Jira Cloud API + 인증
  ├── ArcadeCore/             미러 저장소 · 동기화 · 이벤트 로그 · 규칙 엔진
  ├── ArcadeUI/               셸 · 캐비닛 프로토콜 · 테마 토큰
  └── QuestBoard/             캐비닛 #1
```

의존 방향은 단방향이다: `QuestBoard → ArcadeCore + ArcadeUI → JiraKit`

| 모듈 | 지키는 규칙 |
|---|---|
| `JiraKit` | Jira 통신은 게임을 모른다. XP·레벨 개념이 들어오면 안 된다. |
| `ArcadeCore` | 게임 상태는 화면을 모른다. UI 없이 `swift test`로 전부 검증 가능해야 한다. |
| `ArcadeUI` | 셸은 특정 캐비닛을 모른다. `Cabinet` 프로토콜만 안다. |
| `QuestBoard` | 캐비닛 #1. 향후 캐비닛들과 형제 관계이며 부모가 아니다. |

Swift 모듈은 `public`을 붙이지 않은 타입이 모듈 밖에서 보이지 않으므로, 위 경계는 문서가 아니라 **컴파일러가 강제**한다.

### 3.1 캐비닛 인터페이스

```swift
@MainActor
public protocol Cabinet: Identifiable {
    var id: String { get }
    var title: String { get }
    var marqueeLines: [String] { get }   // 플로어에 보이는 미리보기 3줄
    var accentToken: String { get }      // PaletteTokens의 키. Color가 아니다 — 아래 참고
    func makeView() -> AnyView
}
```

캐비닛은 색이 아니라 **토큰 이름**을 들고 있다. `Color`를 직접 보유하면 캐비닛이 색 값을
결정하게 되어 라이트/다크 전환이 캐비닛을 지나치고, "`ArcadeUI` 뷰 코드에 색 리터럴을 두지
않는다"는 제약도 캐비닛에서 깨진다. 토큰만 들고 셸이 `ArcadeTheme.color(forToken:)`으로
해석하면 테마 전환이 저절로 따라온다.

캐비닛은 셸에 데이터를 요청하지 않는다. 모든 캐비닛이 `ArcadeCore`의 공유 저장소를 각자 읽는다.
따라서 캐비닛끼리 서로를 모르며, 하나를 제거해도 나머지가 깨지지 않는다.

### 3.2 프로젝트 구성 결정

- **`.xcodeproj` 대신 Swift Package + 얇은 앱 타깃**을 쓴다. `.xcodeproj`는 사람이 읽기 어려운 XML이며 파일 추가 시 손상 위험과 리뷰 불가능한 diff를 만든다. 로직을 SPM 패키지에 두면 파일 추가가 곧 파일 생성이고, `swift build && swift test`로 Xcode 없이 대부분의 작업이 돈다.
- **동시성 모델**: 모델과 뷰는 전부 `@MainActor`에 두고, 네트워크 함수만 `async`로 분리한다. 동시성 경계를 네트워크 응답 지점 한 곳으로 제한해 Swift 6 strict concurrency의 학습 부담을 최소화한다.
- **저장소**: SwiftData (`@Model`).

---

## 4. 데이터 모델과 동기화

### 4.1 핵심 아이디어

Jira API는 "현재 상태"만 제공하고 "언제 바뀌었는지"는 제공하지 않는다.
따라서 **앱이 스냅샷을 찍고 비교(diff)하여 시간축을 스스로 만든다.**

```
Jira Cloud ──fetch──▶ 새 응답
                         │  이전 스냅샷과 diff
                         ▼
                   변화 감지 ──▶ IssueEvent 생성 (append-only)
                         │                    │
                         ▼                    ▼
                 IssueSnapshot 갱신     ScoreEngine 집계
                  (현재 상태 미러)      → XP · 레벨 · streak · 위생
```

대안이었던 "Jira `changelog` 전체 복원"은 티켓별 페이지네이션으로 초기 동기화가 느려지고 에러 경로가 늘어나므로 v0.1에서 제외한다(§10).

### 4.2 SwiftData 모델

```swift
@Model final class IssueSnapshot {        // 티켓의 현재 미러
    @Attribute(.unique) var key: String      // "DEMO-9613"
    var summary: String
    var statusName: String                   // 조직 커스텀 값 그대로 ("In Progress")
    var issueType: String
    var priority: String?
    var assigneeAccountId: String?
    var assigneeName: String?
    var dueDate: Date?
    var jiraUpdatedAt: Date
    var firstObservedAt: Date
    var lastObservedAt: Date
}

@Model final class IssueEvent {           // 관측된 변화. 수정·삭제하지 않는다.
    var issueKey: String
    var kind: String        // appeared / statusChanged / touched / dueDateChanged / vanished
    var fromStatus: String?
    var toStatus: String?
    var observedAt: Date
    var actorAccountId: String?
    var xpAwarded: Int
}

@Model final class PlayerProfile {        // 나 + 관측된 팀원. 이벤트에서 재계산 가능한 캐시.
    @Attribute(.unique) var accountId: String
    var displayName: String
    var totalXP: Int
    var lastActiveDay: Date?
    var currentStreak: Int
    var longestStreak: Int
}

@Model final class SyncRun {              // 동기화 이력. "관측 N일차" 표시 및 진단용.
    var startedAt: Date
    var finishedAt: Date?
    var observedIssueCount: Int
    var failureMessage: String?
}
```

**`IssueEvent`를 append-only로 두는 것이 이 설계의 중심이다.**
XP를 `totalXP += 120`처럼 직접 누적하면 규칙을 바꿨을 때 과거를 재계산할 방법이 없다.
이벤트만 남기면 규칙 변경 후 전체 재집계가 가능하며, 이것이 "규칙을 마음껏 실험해도 된다"는 약속을 성립시킨다.

### 4.3 동기화

조회 대상 JQL 2개:

```
내 판   assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC
팀 판   project = DEMO AND statusCategory != Done ORDER BY updated DESC
```

주기: 5분 폴링 + 창 활성화 시 즉시 + 수동 새로고침.
웹훅은 수신 서버가 필요하므로 데스크톱 앱 범위 밖이다.

### 4.4 워크플로 매핑 (설정으로 외부화)

```
To Do      → backlog    In Progress → active
In Review   → review     Verifying   → verify     Done → done
```

`verify`(관측 대상이었던 5번째 단계)를 별도 단계로 두는 이유: 미완료 50건 중 24건이 여기 있으므로
`active`로 취급하면 "진행 중 36건"이라는 무의미한 수치가 나오고, `done`으로 취급하면 정체 문제가 보이지 않는다.

### 4.5 팀 데이터의 한계 (명시)

팀원의 XP는 내 앱이 실행 중일 때 관측된 전이만 반영한다.
따라서 리더보드는 절대 점수가 아니라 **"이번 주 관측된 전이 수"** 로 표시하고, UI에 그 사실을 명시한다.

---

## 5. 게임 규칙

### 5.1 원칙

1. **XP는 관측된 이벤트에만 부여한다.** 상태를 보고 주지 않고 변화를 보고 준다.
2. **후퇴에 벌점을 주지 않는다.** `In Progress → To Do`은 정직한 행동이며, 벌점은 사람을 "거짓 진행 중 유지"로 몰아간다. 후퇴는 0점이며 음수가 아니다.
3. **규칙은 전부 JSON `RuleSet`으로 외부화한다.** 이벤트가 원본이므로 규칙 변경 후 전체 재집계가 가능하다.

### 5.2 습관 ① 정체된 티켓 깨우기 → 보스전

```
정체일 = now − statusEnteredAt

  7일↑   stale   목록 표식
 21일↑   boss    전용 섹션 승격
 45일↑   raid    플로어 마퀴에 경보

깨우기 XP = 40 × min(1 + 정체일 / 14, 4.0)
    21일 → 100 XP,  45일 → 160 XP (상한)
전진 전이인 경우 × 1.5
```

**`statusEnteredAt` 산출은 2단이다.**
Jira는 이 값을 기본 필드로 제공하지 않는다. 우리 이벤트 로그에 해당 티켓의 마지막 `statusChanged`가 있으면 그 시각을 쓰고, 없으면 `jiraUpdatedAt`으로 근사한다.
근사 구간에는 UI에 "근사 기준"임을 표시한다. 관측 사례에서 `updated`가 일괄 갱신되어 있었으므로 초기에는 보스전이 거의 뜨지 않을 수 있다.

### 5.3 습관 ② 상태를 제때 갱신하기 → 위생 게이지

"실제로는 끝났는데 옮기지 않은 티켓"은 직접 관측이 불가능하므로 3가지 프록시로 100점에서 감점한다.

```
WIP 초과      active 5건 초과      초과 1건당 −8    (관측 사례 12건 → −56)
좀비 액티브    active + 7일 무변화   1건당 −6
유령 마감      마감 경과 + 미완료     1건당 −10

위생 ≥ 80인 날 → 데일리 보너스 +50 XP
```

관측 사례(active 12건, 좀비·유령 0건)를 넣으면 정확히 44점이다. 낮게 시작하는 것이 의도이며, 게이지에는 항상 목표선(80)과
"WIP를 5건까지 줄이면 +56" 형태의 **다음 한 걸음**을 함께 표시한다.

**데일리 보너스는 오늘 하루분만 준다.** 열흘 연속 80점을 넘겨도 +50이지 +500이 아니고, 어제 넘겼어도 오늘 못 넘기면 사라진다.

이건 구현상 한계가 아니라 **선택**이다. 이 앱이 유도하려는 습관 중 하나가 "매일 열어보기"인데,
과거 날짜분을 적립하면 "며칠 전에 깨끗했으니 오늘 안 봐도 XP가 쌓인다"는 정반대 신호를 준다.
보드는 **지금 상태**가 중요하지 어제 깨끗했는지는 중요하지 않다.

부수적으로 이 선택이 구현을 단순하게 유지한다 — 일별로 적립하려면 매일의 위생 점수를 이벤트 로그에
남겨야 하는데(미러에는 현재 상태만 있다), 그 복잡도를 감수할 만큼 얻는 것이 없다.

### 5.4 습관 ③ 매일 열어보기 → 연속 기록

```
체크인 조건 = 동기화 성공 + 티켓 1건 이상에 실제 액션(상태 전이 또는 상세 시트 열람)
              "앱만 켜기"는 인정하지 않는다

연속 보너스 = 그날 획득 XP × (1 + min(연속일, 14) × 0.05)   최대 1.7배
주말        = 기본적으로 평일만 카운트
동결        = 주당 1회 자동 소모, 하루 결석을 방어
```

동결 장치는 관대함이 아니라 이탈 방지 설계다. 장기 연속 기록이 하루 실수로 0이 되는 경험은 사용자를 앱에서 떠나보낸다.

두 가지를 명시한다:

- **연속 배수는 이벤트 XP에만 곱한다.** 위생 데일리 보너스(§5.3)에는 곱하지 않는다 — 보너스에 보너스를 곱하는 것이기 때문이다.
- **"평일만 카운트"는 결석 판정에만 적용된다.** 주말에 체크인하면 연속은 이어지고 그날 획득 XP에도 배수가 곱해진다.
  주말을 세지 않는 것은 "금요일 다음 월요일이 결석이 아니다"를 뜻하지, "주말 활동을 무시한다"가 아니다.

### 5.5 습관 ④ 마감 방어 → HP

```
HP = 3 − min(마감 경과 미완료 건수, 3)
경보 단계: D-3 / D-1 / D-0 / 초과
마감 전 완료 시 보너스 = 여유일 × 10 XP (상한 +80)
마감 초과 시 XP 차감 없음 — HP라는 시각적 압박만
```

### 5.6 레벨과 어뷰징 방지

```
레벨 N까지 누적 XP = ⌈100 × N^1.8⌉    LV.5 = 1,812 · LV.10 = 6,310 · LV.20 = 21,972

왕복 차단    같은 티켓의 동일 전이는 24시간 내 1회만 XP
일일 상한    1,200 XP (연속 보너스 적용 후)
되돌림 무효  전이 후 10분 내 원복 시 해당 XP 회수
```

---

## 6. 테마 시스템

시스템 외관을 따르는 **다크·라이트 두 테마를 모두 v0.1에 포함한다.**
다크를 반전시키는 방식은 쓰지 않는다. 두 테마는 각각 별개의 은유를 갖는다.

| | 다크 — *심야의 오락실* | 라이트 — *아케이드 전단지* |
|---|---|---|
| 은유 | CRT 인광, 네온 마퀴 | 리소그래프 인쇄, 스코어 용지 |
| 강조 수단 | 발광(glow), 스캔라인 | 잉크 밀도, 하프톤, 하드 오프셋 섀도 |
| `surfaceBase` | `#0A0B10` | `#E9E9E4` |
| `surfaceRaised` | `#13151F` | `#FFFFFF` |
| `line` | `#262A3A` | `#C6C6BE` |
| `inkPrimary` | `#E8E9F1` | `#16171C` |
| `inkSecondary` | `#878CA3` | `#55575F` |
| `inkTertiary` | `#7A7F94` | `#63655D` |
| `accent` | `#FFB43C` | `#8F4E00` |
| `xpGradient` | `#3DD6C0 → #8B7BFF` | `#0F8C7B → #5A45C7` |
| `boss` | `#FF3D8A` | `#A8115C` |
| `danger` | `#FF6B5E` | `#A81F14` |
| `good` | `#6EE87A` | `#1A6B2C` |

라이트 팔레트는 다크보다 **채도가 높고 명도가 낮다.** 밝은 배경에서 색이 힘을 가지려면 반대 방향으로 가야 하기 때문이며, 두 팔레트는 같은 색의 밝기 조절이 아니라 각각 따로 고른 색이다.

```swift
public struct ArcadeTheme: Sendable {
    public let surfaceBase, surfaceRaised, line: Color
    public let inkPrimary, inkSecondary, inkTertiary: Color
    public let accent, boss, danger, good: Color
    public let xpGradient: [Color]
    public let usesGlow: Bool        // dark: true  / light: false
    public let usesHalftone: Bool    // dark: false / light: true

    public static let dark: ArcadeTheme  = …   // 위 표의 다크 열 값
    public static let light: ArcadeTheme = …   // 위 표의 라이트 열 값
}
```

**표의 hex 값은 대비 테스트로 확정된 값이다.** 구현(계획 1 Task 18)에서 `PaletteTokens`로 코드화하고
WCAG 상대 휘도로 검증했으며, 아래가 `surfaceBase` 대비 실측치다:

| 토큰 | 다크 | 라이트 | 기준 |
|---|---|---|---|
| `inkPrimary` | 16.25 | 14.69 | ≥ 4.5 |
| `inkSecondary` | 5.91 | 5.91 | ≥ 4.5 |
| `inkTertiary` | 4.95 | 4.86 | ≥ 4.5 |
| `accent` | 11.09 | 5.29 | ≥ 3.0 |
| `boss` | 5.88 | 5.95 | ≥ 3.0 |
| `danger` | 7.04 | 6.00 | ≥ 3.0 |
| `good` | 12.62 | 5.42 | ≥ 3.0 |

`inkTertiary`가 양쪽 모두 4.9 안팎으로 여유가 가장 적다 — 조금만 흐리게 조정해도 기준을 깬다.
색 확정의 최종 판정자는 눈이 아니라 테스트다.

- Asset Catalog 대신 코드로 정의한다. SPM 리소스 번들 설정이 불필요하고, 팔레트 대비를 테스트로 검증할 수 있으며, 미리보기에서 두 테마를 나란히 확인할 수 있다.
- 뷰 코드에는 색 리터럴을 두지 않는다. 전부 `theme.*`로만 접근한다. 리터럴이 하나라도 남으면 그 지점이 반대 테마에서 깨진다.
- 효과는 `usesGlow` / `usesHalftone`으로 분기한다. 레벨업 연출은 다크에서 화면 섬광, 라이트에서 스탬프 압인으로 각각 다르게 표현한다.
- 설정: 시스템 따름(기본) · 라이트 고정 · 다크 고정.

---

## 7. 화면 구성

```
① 로그인 ─▶ ② 아케이드 플로어(셸) ─▶ ③ 퀘스트 보드 ─▶ ④ 티켓 상세(시트)
                     │                      │
                     └──────────────────────┴─▶ ⑤ 팀 판 · ⑥ 설정
```

**① 로그인** — 사이트 URL · 이메일 · API Token. 토큰은 Keychain에 저장. `/myself` 1회 호출로 검증. 토큰 발급 페이지 링크 제공.

**② 아케이드 플로어 (셸)** — 캐비닛 3칸 그리드. v0.1에서는 `QUEST BOARD` 1개만 동작하고 나머지 2칸은 `COMING SOON`. 하단에 마지막 동기화 시각과 "관측 N일차".

**③ 퀘스트 보드 (캐비닛 #1)**

```
┌ HUD ─ LV · XP바 · 연속기록 · HP · 위생 ────────────────┐
├──────────────────────────┬───────────────────────────┤
│ 오늘의 퀘스트 (최대 5)     │ 내 스탯 (상태별 건수)        │
│  마감 임박 → 보스 → 진행중  │ 위생 게이지 + 다음 한 걸음   │
│ 보스전 (21일↑ 정체)        │ 파티 (이번 주 관측 전이 수)   │
│ 마감 방어                  │                           │
└──────────────────────────┴───────────────────────────┘
```

"오늘의 퀘스트"는 사용자가 고르지 않고 앱이 5건을 선별한다. 50건 목록을 그대로 주면 그것은 Jira이며, 선택 부담이야말로 제거하려는 마찰이다.

선별 규칙(우선순위 순, 각 그룹 내에서는 정체일 내림차순):

```
1) 마감 경과 또는 D-1 이내      최대 2건
2) boss/raid 등급 정체 티켓      최대 2건
3) active(진행 중) 티켓          나머지 채움
합계 5건. 후보가 부족하면 그만큼만 표시한다.
```

"관측 N일차"는 첫 성공한 `SyncRun` 이후 경과 일수이며, 정체 판정이 근사 기준인 동안 UI에 함께 표시한다.

**④ 티켓 상세 (시트)** — 요약·상태·담당·마감·정체일 + 전이 버튼. 전이는 낙관적 UI + 5초 실행 취소(§8.5).

**⑤ 팀 판** — 프로젝트 전체를 담당자별로 묶은 읽기 전용 화면. 남의 티켓에는 전이 버튼이 없다. 리더보드 수치 옆에 관측 기반임을 명시.

**⑥ 설정** — 워크플로 매핑 표 · WIP 한도 · 동기화 주기 · 테마 · 규칙 JSON 편집 + 전체 재집계 · 진단 정보 복사 · 로그아웃.

---

## 8. 인증 수명주기와 에러 처리

### 8.1 인증 상태 머신

```
signedOut ─로그인─▶ validating ─/myself 성공─▶ signedIn
    ▲                   │                        │ 401
    │                   └─실패─▶ signedOut        ▼
    └──────── 재로그인 ──────────────────────  expired (읽기 전용)
```

`expired`를 별도 상태로 두는 이유: 토큰 만료로 로그아웃시키고 미러를 지우면 사용자는 재로그인 전까지 아무것도 볼 수 없다.
**인증 실패는 쓰기 불가이지 읽기 불가가 아니다.** 미러는 유지하고 배너만 띄우며 전이 버튼만 비활성화한다.

### 8.2 자격증명 저장

- 토큰은 Keychain에만 둔다(`kSecClassInternetPassword`, server = 사이트 호스트, account = 이메일). 앱 DB는 평문 파일이며 백업에 포함되므로 자격증명을 두지 않는다.
- 로그아웃은 Keychain 항목만 삭제하고 미러는 남긴다. 단 **다른 계정으로 로그인하면 미러 전체를 초기화**한다.
- **에러 문자열도 같은 규칙을 받는다.** 앱 DB가 평문이라는 사실은 자격증명뿐 아니라 거기 저장되는
  모든 문자열에 적용된다. `JiraError.transitionRejected(reason:)`는 Jira 응답 본문의
  `errorMessages`를 그대로 나르고 클라이언트의 에러 매핑이 그 케이스를 4xx 전반에 붙이는데,
  Jira 응답에는 이메일이 들어 있다. 따라서 **저장되거나 화면에 닿을 수 있는 실패 문자열에는
  에러 페이로드를 넣지 않는다** — `JiraKit`의 `redactedErrorDescription(_:)`을 거쳐 케이스
  이름이나 타입 이름만 남긴다. `SyncRunRecord.failureMessage`(디스크)와
  `SyncScheduler.State.lastFailure`(화면)가 그 경계다.

### 8.3 OAuth 확장 지점

```swift
public protocol AuthProvider: Sendable {
    var baseURL: URL { get }                             // Basic과 OAuth가 서로 다름
    func authorize(_ request: inout URLRequest) async throws
    func recoverFromUnauthorized() async throws -> Bool  // 갱신 성공 여부
}
```

Basic auth는 `https://{site}.atlassian.net/rest/api/3/...`를,
OAuth 3LO는 `https://api.atlassian.com/ex/jira/{cloudId}/rest/api/3/...`를 사용한다.
즉 추상화 대상은 헤더가 아니라 **"인증 + 베이스 URL"을 함께 만드는 요청 빌더**다.

`APITokenAuth.recoverFromUnauthorized()`는 `false`를 반환한다(토큰은 갱신 불가).
향후 `OAuthAuth`는 refresh를 시도하고 `true`를 반환한다. 호출부는 변경되지 않는다.

### 8.4 에러 분류와 대응

```swift
public enum JiraError: Error {
    case offline
    case unauthorized                             // 401
    case forbidden(resource: String)              // 403
    case notFound(key: String)                    // 404
    case rateLimited(retryAfter: TimeInterval)    // 429
    case transitionRejected(reason: String)       // 400
    case server(status: Int)                      // 5xx
    case decoding(context: String)
}
```

| 에러 | 사용자에게 | 앱 동작 |
|---|---|---|
| `offline` | "오프라인 · 마지막 동기화 N분 전" | 미러로 동작, 전이 비활성 |
| `unauthorized` | 재인증 배너 | `expired` · 읽기 전용 · 미러 유지 |
| `forbidden` | "이 프로젝트를 볼 권한이 없습니다" | 해당 JQL만 비활성 |
| `rateLimited` | 표시하지 않음 | `Retry-After` 존중 후 재시도 |
| `transitionRejected` | Jira가 준 사유 그대로 | 낙관적 UI 롤백 · XP 미부여 |
| `server` | "Jira가 응답하지 않습니다" | 지수 백오프 3회 후 포기 |
| `decoding` | 표시하지 않음(진단에만) | 해당 티켓만 스킵, 나머지 반영 |

**부분 실패를 전체 실패로 만들지 않는다.** 티켓별 파싱 결과를 `Result`로 수집해 1건 실패가 49건을 버리지 않게 한다.

동기화 백오프는 `5초 → 30초 → 2분 → 10분(상한)`이며, 연속 3회 실패해야 UI에 표시한다.

### 8.5 전이 실행 파이프라인

앱에서 유일하게 외부 데이터를 변경하는 경로다.

```
전이 선택
  ├─▶ UI 즉시 반영 + 실행 취소 토스트(5초) ── 네트워크 요청은 아직 보내지 않는다
  │       └─ 취소 → UI 롤백. Jira에 흔적 없음.
  └─▶ 5초 경과 → POST /issue/{key}/transitions
          ├─ 성공 → 해당 티켓 재조회로 실제 상태 확인 → IssueEvent 생성 → XP 부여
          └─ 실패 → UI 롤백 + 사유 표시 + XP 없음
```

- 5초 동안 요청을 보내지 않는 이유: 요청 후 취소하면 되돌리기 전이를 한 번 더 실행해야 하고, 팀원의 Jira 알림에 왕복 기록이 남는다.
- XP는 서버 확인 후에만 부여한다. 화면 상태는 낙관적으로, 점수는 비관적으로.
- 전이 후보는 시트를 열 때 `/transitions`로 조회하며 캐싱하지 않는다. 관리자가 워크플로를 변경하면 캐시된 ID가 즉시 틀린 값이 된다.

### 8.6 무결성과 시계

- `IssueEvent`는 어떤 경우에도 삭제하지 않는다. 스키마 변경 시 `VersionedSchema` 마이그레이션으로 보존한다.
- `PlayerProfile`은 이벤트에서 재계산 가능한 캐시다. 손상되면 삭제 후 재집계한다.
- 연속 기록은 로컬 자정 기준이며 `Calendar.current.startOfDay(for:)`로 판정한다. Jira의 ISO8601 시각은 `Date`로 변환 후 로컬 달력으로 계산해, 타임존이 바뀌어도 "하루"의 정의가 흔들리지 않게 한다.
- 로깅은 `OSLog`. 토큰·이메일은 로그에 남기지 않는다. 진단 정보 복사 시 자격증명은 마스킹한다.

---

## 9. 테스트 전략

```
  UI (SwiftUI)          자동화하지 않음. 수동 확인.
  저장소 (SwiftData)     인메모리 컨테이너로 소수
  JiraKit (네트워크)     고정 응답(fixture)으로 파싱·에러 처리
  ArcadeCore (규칙)     전체의 약 80%
```

프레임워크는 **Swift Testing**(`@Test` / `#expect`)을 쓴다.

### 9.1 테스트 가능성을 위한 설계 제약

모든 규칙 함수는 `now: Date`를 파라미터로 받는다.
함수 내부에서 `Date()`를 직접 호출하면 "7일 정체" 같은 케이스를 검증할 방법이 사라진다.

```swift
struct StagnationClassifier {
    let rules: RuleSet
    func classify(_ issue: IssueSnapshot,
                  statusEnteredAt: Date?,
                  now: Date) -> StagnationTier   // .fresh / .stale / .boss / .raid
}
```

### 9.2 필수 테스트 케이스

| 영역 | 케이스 |
|---|---|
| diff | 새 티켓 → `appeared` / 상태 변경 → `statusChanged(from:to:)` 정확 / `updated`만 변경 → `touched` / 결과에서 사라짐 → `vanished` |
| 정체 | `statusEnteredAt` 우선, 없으면 `jiraUpdatedAt` 폴백 / 경계값 7·21·45일 |
| XP | 21일 정체 깨우기 = 100 XP / 전진 전이 ×1.5 / 후퇴 전이 = 0이며 음수가 아님 |
| 어뷰징 | 24h 내 동일 전이 2회 → XP 1회 / 10분 내 원복 → XP 회수 / 일일 1,200 초과분 미부여 |
| 연속 기록 | 7일 연속 → ×1.35 / 결석 + 동결 보유 → 유지 및 동결 소모 / 동결 소진 → 0 / 주말 제외 |
| 위생 | 관측 사례(active 12건) 입력 시 정확히 44점 |
| 재집계 | **규칙 변경 후 재집계 결과 = 새 규칙으로 처음부터 계산한 결과 (멱등성)**. 단 XP가 정수이고 반올림이 있으므로 "규칙을 N배 하면 총점도 정확히 N배"는 성립하지 않는다 — `round(2x) ≠ 2·round(x)`. 검증할 성질은 스케일 선형성이 아니라 **동일 입력에 대한 결정성**이다. |
| 테마 | 두 테마의 모든 텍스트 토큰이 자기 배경 위에서 대비 4.5:1 이상, 강조색 3:1 이상 |
| JiraKit | 실제 응답 형태 매핑(한글 상태명·`null` 담당자·`duedate` 없음) / 50건 중 1건 파손 시 49건 반영 / 401·429·5xx 처리 / Basic·OAuth 베이스 URL 생성 |

재집계 멱등성 테스트가 가장 중요하다. 이것이 깨지면 규칙을 손볼 때마다 점수가 어긋나고 XP 전체가 신뢰를 잃는다.

### 9.3 fixture 정책

실제 응답을 그대로 커밋하지 않는다. 대표 케이스 8~10건만 발췌하고 요약문은 구조만 남겨 일반화한다.
상태명·워크플로 등 **구조는 실제 그대로** 유지해야 테스트가 의미를 갖는다.

### 9.4 진행 방식

규칙 엔진은 테스트를 먼저 쓴다(§5의 숫자를 그대로 테스트로 옮긴다).
UI와 동기화 배선은 만들고 눈으로 확인하는 편이 빠르므로 구분한다.

---

## 10. v0.1 스코프 경계

### 포함

1. API Token 로그인 + Keychain + `expired` 상태 처리
2. 내 티켓 동기화 (5분 폴링 · 창 활성화 · 수동)
3. 미러 + append-only 이벤트 로그 + diff 엔진
4. 규칙 엔진 — 보스전 · 위생 · 연속 기록 · HP · XP/레벨
5. 아케이드 플로어 셸 (캐비닛 1 + `COMING SOON` 2)
6. 퀘스트 보드 캐비닛
7. 티켓 상세 시트 + 전이 (5초 실행 취소)
8. 팀 판 (읽기 전용)
9. 설정 (워크플로 매핑 · WIP 한도 · 규칙 JSON · 재집계 · 로그아웃)
10. **다크/라이트 테마 + 시스템 외관 연동**

### 제외 (및 이유)

| 제외 항목 | 이유 |
|---|---|
| OAuth 2.0 3LO | `AuthProvider` 자리만 준비. 팀 배포가 실제 필요해지는 시점에. |
| changelog 소급 복원 | 초기 동기화 지연과 에러 경로 증가. LV.1 시작이 게임적으로 자연스러움. |
| 슈팅·터미널 캐비닛 | 셸에 자리만 확보. 기반 검증 후. |
| 사운드 · BGM | 에셋 확보와 볼륨/음소거 UX가 별도 작업. v0.2 1순위 후보. |
| 메뉴바 상주 · 알림 · 위젯 | 별도 타깃과 권한 필요. |
| 코멘트 · 워크로그 쓰기 | 쓰기 표면을 전이 하나로 최소화. |
| 스프린트 · 보드 (Agile API) | 엔드포인트 체계가 별개. |
| 다중 프로젝트 동시 조회 | 1개 고정, 설정에서 교체만 가능. |
| 업적 · 뱃지 | 규칙이 안정된 뒤에 얹어야 의미가 생김. |

---

## 11. 완성 정의

아래가 모두 참이면 v0.1이 끝난 것이다.

```
□ 로그인 후 30초 안에 내 미완료 티켓이 화면에 뜬다
□ 앱을 종료했다 켜도 XP·레벨·연속 기록이 유지된다
□ 앱에서 실행한 전이가 Jira 웹에서 확인된다
□ 네트워크를 끊어도 앱이 열리고 마지막 미러를 보여준다
□ 규칙 JSON을 바꾸고 재집계하면 점수가 일관되게 다시 계산된다
□ 시스템 외관을 라이트/다크로 전환해도 모든 화면이 읽히며, 뷰 코드에 색 리터럴이 없다
□ swift test 전부 통과
```

일정 감각: 순수 로직 1주 · 동기화와 저장 4~5일 · UI 1주 · 테마 2~3일 · 다듬기 3~4일 → **약 3~4주**(Swift 학습 시간 포함).

---

## 12. 리스크

| 리스크 | 완화책 |
|---|---|
| Swift 학습 곡선 (가장 현실적) | 순수 로직(`ArcadeCore`)부터 착수. SwiftUI·SwiftData·동시성을 동시에 만나지 않고 `swift test`만으로 진도가 나가게 한다. |
| 정체 지표 초기 부정확 | 근사 기준임을 UI에 표시. 이벤트가 쌓이면 자동으로 정확한 기준으로 승격. |
| 위생 44점이 개선되지 않으면 좌절 장치가 됨 | 게이지에 목표선과 "다음 한 걸음"을 항상 병기. 점수만 보여주고 방법을 알리지 않으면 잔소리가 된다. |
| v0.1이 아케이드보다 대시보드에 가까움 | 사실. 셸·마퀴·질감·레벨업 연출로 아케이드성을 확보하되, 며칠 사용 후 재미가 부족하면 B 캐비닛을 앞당긴다. |

---

## 13. 결정 기록

| 결정 | 채택 | 기각한 대안 | 이유 |
|---|---|---|---|
| 제품 방향 | 아케이드 플로어 셸 + 퀘스트 보드 캐비닛 | 슈팅 단독 / CRT 클라이언트 단독 | 매일 쓸 만하면서 확장 자리를 남기는 유일한 조합 |
| 사용 범위 | 나 먼저, 팀 배포는 나중 | 처음부터 팀 배포 | 개발자 콘솔 앱 등록·심사 없이 즉시 시작. 추상화로 전환 비용 흡수 |
| 인증 | API Token + Keychain, `AuthProvider` 추상화 | OAuth 2.0 3LO 선구현 | 위와 동일. 베이스 URL까지 포함해 추상화 |
| 스택 | SwiftUI 네이티브 | Tauri 2 / Electron | Keychain·시스템 외관·성능이 퍼스트파티. Rust 툴체인 부재. 네이티브 앱이라는 목표에 부합 |
| 상태 저장 | 로컬 미러 + append-only 이벤트 로그 | 스테이트리스 / changelog 전체 복원 | 연속 기록·위생 점수가 성립하려면 시간축이 필요. changelog는 비용 대비 이득이 낮음 |
| Jira 쓰기 범위 | 상태 전이만 | 코멘트·워크로그 포함 | 위험 표면 최소화. 게임 상태는 100% 로컬 파생 |
| 프로젝트 구성 | SPM 패키지 + 얇은 앱 타깃 | `.xcodeproj` 중심 | 파일 추가가 안전하고 diff가 읽히며 `swift test` 루프가 빠름 |
| 테마 | 다크 + 라이트 (별개 은유) | 다크 단일 | 사용자 요청. 반전이 아닌 별도 팔레트로 설계 |
