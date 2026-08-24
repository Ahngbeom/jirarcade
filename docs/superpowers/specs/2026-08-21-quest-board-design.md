# 퀘스트 보드 설계 (계획 2b-1)

- 작성일: 2026-08-21
- 상태: 확정 (구현 계획 작성 대기)
- 선행: `docs/superpowers/specs/2026-08-12-jirarcade-design.md` (v0.1 전체 설계)
- 선행: `docs/superpowers/specs/2026-08-14-app-shell-design.md` (앱 셸)
- 대상 플랫폼: macOS 15+ / Swift 6.2 / SwiftUI

---

## 1. 배경과 범위

앱 셸(2a)이 끝나면서 로그인·매핑·동기화가 돌고 아케이드 플로어가 뜬다. 이벤트가 쌓이고
XP가 계산되지만 **정작 티켓은 한 건도 화면에 없다.** 관측 캐비닛이 "관측 15일차 · LV.12"라고
말할 뿐이다.

이 계획은 내 티켓을 화면에 올리고, 앱에서 상태를 옮길 수 있게 한다. 끝나면 이 앱은
"동작하지만 볼 게 적은 앱"에서 **매일 여는 앱**이 된다.

| | 범위 |
|---|---|
| **2b-1** (이 문서) | 퀘스트 보드 캐비닛 · 정체 시간축 · 상태 전이 |
| 2b-2 | 티켓 상세 · 제목/본문 수정 · 댓글 |
| 2b-3 | 스프린트 보드 (Agile API) |

셋을 한 문서에 담지 않는 이유: 서로 독립적인 서브시스템이고, 2b-2와 2b-3은 각각
**v0.1 스펙 §10이 명시적으로 제외한** 영역이라 그 제외 결정을 뒤집는 근거를 따로 세워야 한다.
2b-1은 셋 중 유일하게 새 네트워크 표면이 없다 — 필요한 데이터가 전부 로컬 미러에 있다.

### 1.1 v0.1 스펙에서 뒤집는 결정 — 큐레이션에서 전량으로

v0.1 스펙 §7 ③은 퀘스트 보드를 **"오늘의 퀘스트 최대 5건, 앱이 선별"** 로 못박고 이렇게 적었다:

> "50건 목록을 그대로 주면 그것은 Jira이며, 선택 부담이야말로 제거하려는 마찰이다."

**이 결정을 뒤집는다.** 내 미완료 티켓을 단계별로 전량 보여준다.

뒤집는 이유는 두 가지다. 첫째, 2b-3에서 스프린트 보드가 오면 그 화면은 본질적으로 전량이다 —
스프린트에 담긴 티켓 중 5건만 보여주는 스프린트 보드는 성립하지 않는다. 한 앱 안에서 한 화면은
큐레이션하고 다른 화면은 전량이면 사용자는 어느 화면이 무엇을 숨기는지 매번 되짚어야 한다.
둘째, 큐레이션의 전제는 "고르는 것이 부담"이었는데, 그 부담을 실제로 만드는 것은 목록의 길이가
아니라 **무엇이 급한지 알 수 없다는 것**이다. 이 계획은 그 문제를 목록을 자르는 대신
§2의 시간축으로 푼다.

**대신 지킬 것:** 전량을 보여주되 Jira와 같은 모양으로 보여주지 않는다. 그 구분이 §2다.

---

## 2. 정체 시간축 — 화면의 주 구조

README 첫 문단이 이 앱의 존재 이유를 이렇게 적었다:

> "Jira는 '이 티켓이 며칠째 멈춰 있었는가'를 알려주지 않습니다. 현재 상태만 줄 뿐 시간축이 없습니다."

앱이 스냅샷을 찍고 이벤트 로그를 만드는 이유가 그 시간축을 갖기 위해서다. 그런데 티켓을 카드
격자에 늘어놓으면 그 시간축은 카드 구석의 배지로 쪼그라들고, 화면은 또 하나의 칸반이 된다.
**Jira가 못 하는 일을 하려고 만든 데이터를 Jira와 같은 모양으로 보여주게 된다.**

그래서 시간축을 화면의 주 구조로 삼는다. 단계마다 가로 레인을 깔고, 티켓을 정체일에 따라
왼쪽에서 오른쪽으로 배치한다.

```
ACTIVE                                        4건 · 한도 5
 0d─────────────┼7d─────────────┼21d════════════╪45d+
       ▪                  ▪            ▪         ▪
    MPT-201            MPT-77       MPT-88    MPT-104
    배너 교체           로그인 리팩터   로그 수집   결제 연동
                                     BOSS      RAID  D-2

REVIEW                                              2건
 0d─────────────┼7d─────────────┼21d════════════╪45d+
    ▪    ▪
 MPT-150 MPT-3

BACKLOG                                             9건  ▸

매핑되지 않은 상태                                    1건  ▸
```

### 2.1 축의 눈금은 `RuleSet`에서 온다

눈금은 `0 / staleDays / bossDays / raidDays`다. 기본값으로는 `0 / 7 / 21 / 45`이며,
`StagnationClassifier`가 등급을 가르는 바로 그 경계값이다.

축을 임의의 눈금(예: 0/10/20/30)으로 그리지 않는 이유: 그러면 화면이 등급과 무관한 눈금을
말하면서 카드에는 `BOSS`라고 적는 두 개의 설명을 갖게 된다. 눈금이 곧 경계값이면
**"이 티켓은 왜 보스인가"에 화면이 스스로 답한다** — 세 번째 눈금을 넘었기 때문이다.

설정에서 규칙 JSON을 고치면 축이 따라 움직인다. 이것은 부작용이 아니라 의도다.

### 2.2 위치는 구간별 선형(piecewise linear)이다

정체일을 축 위 위치로 옮길 때 `days / raidDays`로 선형 매핑하면 안 된다. 0–7일 구간이
축의 15%에 불과한데 실제 티켓은 대부분 그 구간에 있다 — 대다수가 왼쪽 끝에 뭉쳐 서로를 가리고,
정작 화면의 85%는 비어 있게 된다.

**각 눈금 구간이 축에서 같은 폭을 차지하게 한다.** 눈금이 4개면 구간은 3개이고 각각 1/3이다:

| 정체일 | 위치 |
|---|---|
| 0일 | 0.000 |
| 7일 (stale 경계) | 0.333 |
| 21일 (boss 경계) | 0.667 |
| 45일 이상 (raid 경계) | 1.000 |
| 3일 | 0.143 (0–7 구간을 선형 보간) |
| 30일 | 0.792 (21–45 구간을 선형 보간) |

결과적으로 등급이 낮은 구간이 넓게 펼쳐지고 오래된 구간이 압축된다. 이것은 데이터 분포에
맞춘 절충이 아니라 **읽고 싶은 것에 맞춘 배분**이다 — 45일과 50일의 차이는 이미 둘 다
raid라는 사실 앞에서 의미가 작고, 5일과 10일의 차이는 등급이 갈리므로 크다.

### 2.3 `raidDays` 초과는 오른쪽 끝에 클램프한다

3년 정체 티켓 하나가 축 전체를 압축해 나머지를 왼쪽 끝에 뭉치게 하는 것을 막는다.
클램프된 티켓은 카드에 실제 일수를 그대로 표기하므로 정보는 잃지 않는다.
축의 마지막 라벨은 `45d+`로 적어 그 너머가 접혀 있다는 사실을 드러낸다.

### 2.4 겹침 해소 — 결정적 lane packing

위치가 가까운 티켓은 수직으로 쌓는다. 알고리즘은 greedy lane packing이다:

1. 슬롯을 `position` 오름차순으로 정렬한다. **동률이면 `issueKey` 사전순으로 가른다.**
2. 각 슬롯을 "이미 배치된 마지막 슬롯과의 간격이 `minimumSpacing` 이상인" 가장 낮은 row에 넣는다.
3. 들어갈 row가 없으면 새 row를 만든다.

동률 타이브레이크를 명시하는 이유는 후속 항목 §2.2와 같다 — Swift의 `sorted(by:)`는 안정
정렬이 아니므로, 같은 정체일 티켓 두 건의 상하 순서가 실행마다 뒤집힐 수 있다. 데이터는
틀어지지 않지만 화면이 매 렌더마다 흔들리고 테스트가 비결정적이 된다.

`minimumSpacing`은 **뷰가 넘긴다.** `ArcadeCore`는 카드 폭도 화면 폭도 모르므로 정규화 단위
(축 전체 대비 비율)로 받는다. 창을 좁히면 뷰가 더 큰 값을 넘겨 자연히 더 많이 쌓인다.

---

## 3. 계산을 `ArcadeCore`로 내린다

후속 항목 §3.1이 지적했듯 **`ArcadeUI`에는 테스트 타깃이 없다.** 뷰 배선은 `ModuleBoundaryTests`의
소스 텍스트 검사로만 지켜지고, 그런 테스트는 이름이 주장하는 것을 실제로 검증하지 못한다.
그 항목의 권고가 "분기 로직을 도메인으로 내리는 쪽이 값이 크다"였고, 이 계획은 그대로 따른다.

**배치 계산 전부가 `ArcadeCore`의 순수 함수다. 뷰는 좌표를 받아 그리기만 한다.**

### 3.1 `BoardLayout`

```swift
public struct BoardSlot: Sendable, Equatable {
    public let issue: ObservedIssue
    public let daysStagnant: Int          // 클램프 전 실제 일수
    public let tier: StagnationTier
    public let position: Double           // 0.0…1.0, 구간별 선형 + 클램프
    public let row: Int                   // 겹침 해소 결과
    public let isApproximate: Bool        // statusEnteredAt이 없어 근사 기준을 썼다
    public let dueState: DueState
}

public enum DueState: Sendable, Equatable {
    case none
    case dueIn(days: Int)                 // 미래 마감 전부. 강조 기준은 뷰가 정한다
    case overdue(days: Int)
}

public struct BoardLane: Sendable, Equatable {
    public let stage: Stage
    public let slots: [BoardSlot]
    public let rowCount: Int
}

public struct AxisTick: Sendable, Equatable {
    public let days: Int
    public let position: Double
    public let isTerminal: Bool           // 마지막 눈금 — "45d+"로 그린다
}

public enum BoardLayout {
    public static func lanes(
        issues: [ObservedIssue],
        statusEnteredAt: [String: Date],
        workflow: WorkflowMap,
        rules: RuleSet,
        minimumSpacing: Double,
        now: Date,
        calendar: Calendar
    ) -> BoardSnapshot

    public static func axisTicks(rules: RuleSet) -> [AxisTick]
}

public struct BoardSnapshot: Sendable, Equatable {
    public let lanes: [BoardLane]         // backlog → active → review → verify 순
    public let unmappedIssues: [ObservedIssue]
    public let axis: [AxisTick]
}
```

`lanes`가 `Stage.order` 순으로 나오되 **`done`은 포함하지 않는다** (§7.2).

### 3.2 `statusEnteredAt`의 출처

정체일은 "현재 상태에 들어간 시각"에서 나온다. 이 값은 지금 **`ScoreEngine.recompute`의 지역
변수로만 존재한다**(`ScoreEngine.swift:64`) — 이벤트 로그를 순회하며 재구성하고 계산이 끝나면
버린다. 밖에서 읽을 방법이 없다.

`ArcadeCore`에 순수 함수를 신설한다:

```swift
public enum StatusTimeline {
    /// 이벤트 로그에서 티켓별 **최종** statusEnteredAt을 뽑는다.
    /// `.statusChanged`의 observedAt으로 갱신하며, 그 규칙은 ScoreEngine과 같다.
    public static func latestStatusEntry(from events: [DomainEvent]) -> [String: Date]
}
```

`ScoreEngine`과 코드를 공유하지 않는 이유: `recompute`는 순회 **도중의** 시점별 값이 필요하고
(각 이벤트를 그 시점의 기준선으로 채점한다) 이 함수는 최종값만 필요하다. 하나로 합치면
recompute가 중간 상태를 밖으로 흘리거나 이 함수가 필요 없는 전체 순회를 하게 된다.

대신 **두 경로가 같은 규칙을 쓴다는 것을 테스트로 고정한다** — 같은 이벤트 로그를 두 경로에
넣어 마지막 `.statusChanged` 시각이 일치하는지 확인한다. 한쪽만 고치면 그 테스트가 깨진다.

`statusEnteredAt`이 없는 티켓(관측 시작 전부터 그 상태였고 백필도 못 채운 경우)은
`jiraUpdatedAt`으로 폴백하고 `isApproximate: true`를 세운다. `StagnationClassifier.isApproximate`가
이미 이 목적으로 노출돼 있다. 화면은 그 티켓의 정체일 옆에 근사 표시를 단다 — 관측 이력이
없는 티켓의 정체일을 확정처럼 보여주면, 이 앱이 정직하려고 만든 "관측한 것만 안다"는 원칙이
화면에서 깨진다.

---

## 4. 상태 전이 파이프라인

v0.1 스펙 §8.5를 그대로 구현한다. 앱에서 유일하게 외부 데이터를 변경하는 경로다.

```
전이 선택
  ├─▶ 카드가 즉시 새 레인으로 이동 + "실행 취소" (5초) ── 요청은 아직 보내지 않는다
  │       └─ 취소 → 카드 원위치. Jira에 흔적 없음.
  └─▶ 5초 경과 → POST /issue/{key}/transitions
          ├─ 성공 → syncNow(.manual) → diff가 이벤트 생성 → XP
          └─ 실패 → 카드 원위치 + 사유 표시 + XP 없음
```

### 4.1 XP를 직접 주지 않는다

전이가 성공하면 **XP를 부여하는 대신 동기화를 한 번 트리거한다.** diff 엔진이 미러와 새 상태를
비교해 `.statusChanged` 이벤트를 만들고, `ScoreEngine`이 여느 이벤트와 똑같이 채점한다.

이것이 이 앱의 근본 불변식을 지키는 방법이다 — **점수는 관측 로그의 순수 함수이고, 앱은
자기가 한 일을 자기가 채점하지 않는다.** XP 부여 경로가 둘이 되면 재집계했을 때 결과가
달라지고, "규칙을 바꿔도 과거를 재계산할 수 있다"는 README의 약속이 깨진다.

부수 효과로 `AbuseGuard`의 왕복 차단·일일 상한이 앱에서 실행한 전이에도 그대로 적용된다.

### 4.2 5초 동안 요청을 보내지 않는다

스펙 §8.5의 근거를 그대로 따른다: 요청을 보낸 뒤 취소하면 되돌리기 전이를 한 번 더 실행해야
하고, 팀원의 Jira 알림에 왕복 기록이 남는다.

대기 시간은 `AppSettings.transitionUndoWindow`에 둔다(기본 `.seconds(5)`). `RuleSet`이 아닌
이유는 이 값이 점수에 영향을 주지 않기 때문이다 — `AppSettings`의 doc-comment가 정한 경계다.
테스트는 이 값을 밀리초로 줄여 실제로 5초를 기다리지 않는다.

### 4.3 전이 후보는 캐싱하지 않는다

카드의 전이 메뉴를 열 때마다 `/issue/{key}/transitions`를 조회한다. 관리자가 워크플로를
변경하면 캐시된 전이 ID는 즉시 틀린 값이 된다(스펙 §8.5).

`JiraClient.transitions(issueKey:)`와 `performTransition(issueKey:transitionId:)`는 **이미 있다**.
호출부만 없다.

### 4.4 동시 전이 — 티켓마다 독립된 타이머

대기 중인 전이는 **티켓 키로 색인된 딕셔너리**이며, 각 항목이 자기 타이머를 갖는다.

한 번에 하나만 대기하게 하면 "앞의 것을 즉시 확정한다"는 규칙이 따라붙고, 그러면 세 티켓을
연달아 정리하는 흔한 흐름에서 앞의 두 건이 취소 기회를 잃는다. 5초 실행 취소가
"다른 티켓을 건드리지 않는 한"이라는 숨은 조건을 갖게 되는 셈이다. 상태를 하나로 줄이려는
절약이 사용자와의 약속을 깎을 이유가 없다.

같은 티켓의 전이를 다시 고르면 그 티켓의 대기를 **교체하고 타이머를 다시 시작한다** —
잘못 골랐을 때 취소하고 다시 고르는 것과 결과가 같아야 한다.

전이가 대기 중인 티켓은 카드에 남은 시간과 취소가 함께 붙는다. 화면 하단에 토스트를 쌓지
않는 이유: 대기가 여럿일 때 어느 토스트가 어느 카드인지 사용자가 다시 대응시켜야 한다.
카드가 이미 그 티켓을 가리키고 있다.

### 4.5 실패

| 실패 | 처리 |
|---|---|
| `transitionRejected` (400) | 카드 원위치 + "Jira가 이 전이를 거부했습니다" + **Jira에서 열기** |
| `unauthorized` (401) | `AppModel`의 기존 만료 경로로 넘긴다. 카드 원위치 |
| `offline` | 카드 원위치 + "연결되지 않았습니다". 재시도는 사용자가 다시 고른다 |
| 그 외 | 카드 원위치 + 종류만 표시 |

**Jira가 준 거부 사유를 화면에 옮기지 않는다.** 400의 사유는 대부분 "필수 필드가 비어
있다"라서 실질적 안내가 되지만, `redactedErrorDescription`의 doc-comment가 명시하듯
`transitionRejected(reason:)`는 Jira 응답의 `errorMessages`를 그대로 담고 그 본문에는
이메일이 섞일 수 있다. v0.1 스펙 §8.4는 **화면에 닿는 실패 문자열**까지 이 제약 아래 둔다.

사유를 버리는 대신 그 자리에 **해당 티켓의 Jira 페이지로 가는 링크**를 둔다. 전이가
거부되는 이유는 앱이 채울 수 없는 정보를 Jira가 요구하기 때문이고, 그 정보를 채울 수
있는 곳은 어차피 Jira다 — 사유를 읽는 것보다 그곳으로 가는 것이 한 단계 짧다.

이 링크는 실패 상황에만 쓰이지 않는다. 카드에서 언제든 Jira로 갈 수 있어야 한다 —
이 앱이 하지 않는 일(본문 읽기·첨부·이력)이 아직 많고, 2b-2가 오기 전까지는 전부
그쪽에 있다. `AtlassianLinks`에 `issue(key:site:)`를 더하고, 사이트 호스트는
`AppModel`이 노출한다(자격증명 전체가 아니라 호스트 문자열 하나만).

**낙관적 롤백은 미러를 건드리지 않는다.** 대기 중인 전이는 `AppModel`의 메모리 상태이고
보드가 그것을 미러 위에 겹쳐 그린다. 롤백은 그 메모리 상태를 지우는 것이며, 스토어에는
처음부터 아무것도 쓰지 않았다.

---

## 5. 화면 구조 — `Cabinet`에 표시 방식을 더한다

퀘스트 보드는 매일 여러 번 여는 화면이다. 지금 캐비닛은 `minWidth: 420` 시트로 열리는데
(`ArcadeFloorView.swift`), 시트는 잠깐 들여다보고 닫는 것이라 맞지 않는다.

`Cabinet` 프로토콜에 표시 방식을 더한다:

```swift
public enum CabinetPresentation: Sendable { case sheet, fullScreen }

public protocol Cabinet: Identifiable {
    // ...기존 요구사항...
    var presentation: CabinetPresentation { get }
}
```

기본 구현을 `.sheet`로 두어 `ObservationCabinet`은 손대지 않는다. 퀘스트 보드만 `.fullScreen`을
돌려준다.

`.fullScreen`은 같은 창 안에서 플로어를 대체하고, 상단에 `◂ FLOOR`가 돌아가는 길이 된다.
새 창이나 `NavigationStack`을 쓰지 않는 이유: 창이 늘면 동기화 배너·경고 배너가 어느 창에
붙어야 하는지가 새 문제가 되고, `NavigationStack`은 이 앱에 아직 다른 계층이 없어 과하다.

**셸은 여전히 특정 캐비닛을 모른다.** `ArcadeFloorView`가 아는 것은 `cabinets` 배열과
`presentation` 값뿐이다.

---

## 6. `AppModel`이 새로 노출하는 것

```swift
/// 현재 미러. 보드가 읽는다.
public private(set) var issues: [ObservedIssue]
/// 티켓별 현재 상태 진입 시각. 없으면 보드가 jiraUpdatedAt으로 폴백한다.
public private(set) var statusEnteredAt: [String: Date]
/// 실효 워크플로 맵(사용자 매핑 + 폴백). 보드가 단계를 가를 때 쓴다.
public var effectiveWorkflowMap: WorkflowMap { get }
/// 위생 리포트. HUD가 읽는다.
public private(set) var hygiene: HygieneReport?

/// 대기 중인 전이. 티켓 키로 색인되며 보드가 미러 위에 겹쳐 그린다.
public private(set) var pendingTransitions: [String: PendingTransition]
/// 티켓별 마지막 전이 실패 사유. 사용자가 지우거나 다음 전이 요청이 덮는다.
public private(set) var transitionFailures: [String: String]

public func availableTransitions(for issueKey: String) async throws -> [JiraTransition]
public func requestTransition(issueKey: String, transition: JiraTransition)
public func cancelPendingTransition(issueKey: String)
public func dismissTransitionFailure(issueKey: String)
```

```swift
public struct PendingTransition: Sendable, Equatable {
    public let issueKey: String
    public let transitionId: String
    /// 낙관적으로 그릴 상태명. 보드가 이 값으로 단계를 다시 가른다.
    public let toStatusName: String
    /// 되돌릴 때 쓸 원래 상태명. 미러를 다시 읽지 않는 이유는 그 사이 동기화가
    /// 미러를 갱신했을 수 있고, 그러면 롤백이 엉뚱한 상태로 되돌린다.
    public let fromStatusName: String
    /// 요청을 보낼 시각. 카드가 남은 시간을 그린다.
    public let firesAt: Date
}
```

`issues`·`statusEnteredAt`·`hygiene`은 **`refreshSummaries()`에서 함께 갱신한다.**

동기화 성공(`AppModel.swift:379`)과 로그인·백필 종료(`refreshDerivedState()`)가 공통으로
지나는 유일한 지점이 이 함수이고, 이미 `store.loadEvents()`와 `store.loadMirror()`를 둘 다
읽고 있다 — 보드가 필요로 하는 것이 정확히 그 둘이다. 새 갱신 시점도, 새 스토어 읽기도
만들지 않는다.

다만 이 함수는 더 이상 요약만 갱신하지 않으므로 **`recomputeFromLog()`로 개명한다.**
호출부는 세 곳이다(`refreshDerivedState`·`performSync`·`confirmMapping`). 이름이 하는 일보다 좁으면 다음 사람이 보드 갱신을 여기 두지 않고
새 경로를 만든다.

`effectiveWorkflowMap`은 **매 접근마다 디스크를 치면 안 된다.** 후속 항목 §4.2가 지적한
`currentMapping`/`currentFallbacks`와 같은 함정이며, 보드는 렌더마다 이 값을 읽는다.
갱신 시점에 한 번 읽어 저장한다.

---

## 7. 빈 상태와 경계

### 7.1 매핑되지 않은 상태의 티켓

`workflow.stage(for:)`가 nil인 티켓은 **어느 레인에도 들어가지 못한다.** 그대로 두면 보드에서
조용히 사라지고 사용자는 티켓이 없어졌다고 생각한다.

`BoardSnapshot.unmappedIssues`로 따로 모아 보드 하단에 접힌 레인으로 둔다. 펼치면 목록과
"매핑 고치기" 버튼이 나오고, 버튼은 기존 매핑 마법사로 간다.

마법사는 `phase`를 `.mappingWorkflow`로 바꾸므로 `RootView`가 화면 전체를 마법사로 갈아끼우고
**보드는 닫힌다.** 마법사를 마치면 `.ready`로 돌아와 플로어가 뜨며, 사용자는 보드를 다시
열어야 한다. 보드 위에 마법사를 겹치지 않는 이유는 마법사가 이미 전체 화면 흐름이고,
그 안에서 보드로 돌아가는 두 번째 경로를 만들면 `.mappingWorkflow`로 들어오는 다른 경로
(온보딩·설정)와 종료 동작이 갈리기 때문이다.

이 개수는 플로어 마퀴의 `⚠ 매핑되지 않은 상태 N개` 배지와 **다를 수 있다** — 배지는 상태명을
세고 이 레인은 티켓을 센다. 후속 항목 §1.3이 지적한 개수 불일치와는 다른 축이므로,
문구를 각각 "상태 N개" / "티켓 N건"으로 명확히 갈라 적는다.

### 7.2 `done` 레인은 그리지 않는다

동기화 JQL이 `assignee = currentUser() AND statusCategory != Done`이므로 **미러에 완료 티켓이
없다.** `done` 레인은 언제나 비어 있다. 영구히 빈 레인을 그리는 것은 "여기 뭔가 들어와야 하는데
비어 있다"는 잘못된 신호다.

전이로 티켓을 완료하면 다음 동기화에서 미러에서 사라지고 `.vanished` 이벤트가 남는다.
보드에서는 카드가 사라진다 — 그것이 정확한 표현이다.

### 7.3 티켓이 0건

동기화 전이면 "아직 동기화하지 않았습니다", 동기화했는데 0건이면 "담당한 미완료 티켓이
없습니다". 둘을 구분하는 근거는 `lastSync`이며 `ObservationCabinet`이 이미 같은 판정을 쓴다.

### 7.4 오프라인

미러는 로컬이므로 보드는 그대로 뜬다. 전이 메뉴만 열리지 않는다(`/transitions` 조회 실패).
v0.1 완성 정의의 "네트워크를 끊어도 앱이 열리고 마지막 미러를 보여준다"가 이 화면에서
처음 실제 의미를 갖는다.

---

## 8. 시각 언어

팔레트는 `PaletteTokens`에 확정돼 있고 `ContrastTests`가 WCAG 대비를 강제한다. 새 색은 넣지
않는다. `ModuleBoundaryTests.viewsUseThemeTokensRatherThanColorLiterals`가 뷰의 색 리터럴을
막으므로 새 뷰도 자동으로 그 규칙 아래 들어온다.

| 요소 | 처리 |
|---|---|
| `fresh` | `inkTertiary` 점. 존재는 하되 시선을 끌지 않는다 |
| `stale` | `accent` 점 |
| `boss` | `boss` 색 점 + 카드 테두리 |
| `raid` | `boss` 색 + **채운 배경**. 색이 아니라 구조로 boss와 가른다 |
| 마감 경과 | `danger` 표기 |
| 마감 임박 (D-3 이내) | `accent` 표기 |
| 근사 정체일 | 일수 옆 `~` + 툴팁 |
| 축 눈금선 | `line`. boss 구간부터는 이중선으로 무게를 준다 |

raid에 새 색을 만들지 않고 구조로 가르는 것은 이 프로젝트의 기존 판단을 따른 것이다 —
`RootView.warningBanner`가 "팔레트에 경고 전용 토큰이 없으므로 색 대신 구조로 가른다"고
같은 결정을 이미 내렸다.

**HUD**는 레인 위에 한 줄로 둔다: 시즌 LV·XP 바 · 연속 기록 · HP · 위생 점수 · 다음 한 걸음.
`HygieneNextStep`은 구조화된 값이므로 문장으로 만드는 일은 뷰가 한다(`HygieneCalculator`의
doc-comment가 정한 경계).

**모션**은 전이 하나에만 쓴다. 카드가 레인 사이를 이동하는 것이 유일한 애니메이션이고,
실행 취소를 누르면 같은 경로를 되돌아간다 — 그 되돌아감이 "아직 Jira에 아무 일도 없었다"를
말한다. `reduceMotion`이 켜져 있으면 위치만 즉시 바뀐다.

---

## 9. 테스트 전략

| 계층 | 무엇을 |
|---|---|
| `ArcadeCoreTests` | `BoardLayout` 전부 — 구간별 선형 위치, 클램프, 겹침 packing, 동률 타이브레이크, 미매핑 분리, `done` 제외, 빈 입력 |
| `ArcadeCoreTests` | `StatusTimeline.latestStatusEntry` + `ScoreEngine`과 규칙이 일치한다는 교차 검증 |
| `ArcadeCoreTests` | `axisTicks`가 `RuleSet`을 따라 움직인다 (기본값 아닌 규칙으로도) |
| `ArcadeAppTests` | 전이 파이프라인 — 창 안 취소는 요청을 보내지 않는다 / 창이 지나면 보낸다 / 성공 후 동기화가 돈다 / 실패하면 대기가 지워진다 / 401은 만료 경로로 간다 / 두 티켓의 대기가 서로 독립적으로 만료된다 / 같은 티켓 전이는 교체하고 타이머를 다시 시작한다 |
| `ArcadeAppTests` | `refreshDerivedState()`가 `issues`·`statusEnteredAt`·`hygiene`을 함께 갱신한다 |
| `ArcadeUI` | 타깃 없음. 소스 텍스트 검사(색 리터럴)만 기존대로 적용된다 |

전이 테스트는 `StubHTTPClient`와 주입된 시계로 돈다. `transitionUndoWindow`를 밀리초로 줄여
실제로 기다리지 않는다 — 기존 `SyncSchedulerTests`가 5분 타이머와 30초 쿨다운을 같은 방식으로
검증한다.

**`ArcadeUI`에 테스트 타깃을 만들지 않는다.** 후속 항목 §3.1이 그 대안으로 "분기 로직을
도메인으로 내리는 쪽이 값이 크다"고 했고, §3이 그대로 따랐다. 보드 뷰에 남는 판단은
"슬롯을 좌표에 놓는다"뿐이다.

---

## 10. 스코프 경계

### 포함

1. 퀘스트 보드 캐비닛 (`.fullScreen`)
2. 정체 시간축 레인 — 구간별 선형 · 클램프 · 겹침 packing
3. `BoardLayout` / `StatusTimeline` 순수 함수와 테스트
4. HUD (시즌 LV·XP · 연속 · HP · 위생 · 다음 한 걸음)
5. 상태 전이 + 5초 실행 취소 + 실패 처리
6. 매핑되지 않은 상태의 티켓 레인
7. `Cabinet.presentation`
8. 카드에서 Jira 티켓 페이지 열기

### 제외

| 제외 항목 | 이유 |
|---|---|
| 티켓 상세 시트 | 2b-2. 제목/본문 수정·댓글과 한 화면이라 함께 설계해야 한다 |
| 제목·본문 수정, 댓글 | 2b-2. ADF 처리와 XP 규칙 재검토가 필요하다 |
| 스프린트 · 보드 | 2b-3. `AuthProvider.baseURL`이 `/rest/api/3`에 묶여 있어 계약 변경이 선행한다 |
| 팀 판 | v0.1 스펙 §7 ⑤. 남의 티켓은 미러에 없다 |
| 드래그로 단계 이동 | `WorkflowMap`이 status→stage 단방향 1:N이라 드롭 후 status 선택이 또 필요하다 |
| 완료 티켓 표시 | JQL 변경이 필요하고, 그러면 미러·diff·`.vanished` 의미가 전부 바뀐다 |
| 레벨업 연출 · CRT 효과 | 별도 작업 |

---

## 11. 완성 정의

```
□ 플로어에서 QUEST BOARD를 열면 내 미완료 티켓이 단계별 레인에 전량 뜬다
□ 티켓이 정체일에 따라 축 위에 놓이고, 눈금이 RuleSet의 경계값과 일치한다
□ 규칙을 바꾸면 축 눈금과 등급이 함께 움직인다 — **자동 테스트가 보장**(§11.1)
□ 관측 이력이 없는 티켓의 정체일에 근사 표시가 붙는다
□ 매핑되지 않은 상태의 티켓이 보드에서 사라지지 않는다
□ 카드에서 상태를 옮기면 5초 안에 취소할 수 있고, 취소하면 Jira에 아무 일도 없다
□ 5초가 지나 전이가 성공하면 Jira 웹에서 확인되고, 다음 동기화에서 XP가 붙는다
□ 전이가 실패하면 카드가 제자리로 돌아가고 안내와 Jira 링크가 뜨며 XP가 없다
□ 어떤 화면 문구에도 Jira 응답 본문 조각이 섞이지 않는다
□ 라이트/다크 모두에서 읽히며 뷰 코드에 색 리터럴이 없다
□ swift test 전부 통과
```

### 11.1 수동으로 확인할 수 없는 항목

"규칙을 바꾸면 축이 따라 움직인다"는 **손으로 확인할 수단이 이 앱에 없다.** v0.1 스펙 §7 ⑥이
설정 화면에 규칙 JSON 편집을 계획했지만 아직 구현되지 않았고, `RuleSet`을 파일에서 읽는 경로도
없다 — `RuleSet.default`가 유일한 출처다.

그 성질은 `BoardAxisTests.ticksFollowACustomRuleSet`이 고정한다. 다른 경계값을 가진 `RuleSet`을
넣어 눈금이 `[0, 3, 10, 20]`으로 따라가는지, 그 규칙에서 10일이 `2/3` 위치에 놓이는지 확인한다.
규칙 편집 UI가 생기면 그때 수동 확인 항목으로 승격한다.

---

## 12. 리스크

| 리스크 | 완화책 |
|---|---|
| 티켓이 많으면 레인이 세로로 길어져 축의 의미가 흐려진다 | `minimumSpacing`을 뷰가 넘기므로 창 폭에 따라 조절된다. 그래도 넘치면 레인별 접기를 넣되, 접힌 레인도 개수는 항상 보인다 |
| 대부분 티켓이 fresh라 축 왼쪽 1/3에만 모인다 | 구간별 선형(§2.2)이 이 경우를 위한 설계다. 그래도 뭉치면 `staleDays` 이하 구간을 더 넓게 배분하는 것을 재검토한다 |
| 낙관적 UI와 미러가 갈라지는 창 | 대기 상태는 메모리에만 있고 미러는 건드리지 않는다. 전이 성공 후 동기화가 끝나면 자연히 합쳐진다. 동기화가 실패하면 카드는 대기 상태를 유지하되 표시를 남긴다 |
| 전이 실행이 `AbuseGuard`의 왕복 차단에 걸려 XP가 0이 된다 | 의도된 동작이다. 다만 사용자가 "왜 XP가 안 붙지"를 알 수 없으므로, 24시간 안에 같은 전이를 반복하면 카드에 그 사실을 표시하는 것을 후속으로 남긴다 |
| `statusEnteredAt` 규칙이 `ScoreEngine`과 갈라진다 | 교차 검증 테스트로 고정한다(§3.2) |

---

## 13. 결정 기록

| 결정 | 채택 | 대안 | 이유 |
|---|---|---|---|
| 목록 범위 | 단계별 전량 | 오늘의 퀘스트 5건 (v0.1 스펙) | 2b-3 스프린트 보드가 본질적으로 전량이라 한 앱에 두 원칙이 공존할 수 없다. 선택 부담은 목록을 자르는 대신 시간축으로 푼다 |
| 주 구조 | 정체 시간축 레인 | 카드 그리드 + 게이지 / 밀도 높은 행 | 이 앱이 가진 유일한 자산이 Jira에 없는 시간축이다. 그것을 배지로 축소하면 화면이 또 하나의 칸반이 된다 |
| 축 눈금 | `RuleSet`의 경계값 | 고정 눈금 (0/10/20/30) | 눈금이 곧 경계값이면 "왜 보스인가"에 화면이 스스로 답한다 |
| 위치 매핑 | 구간별 선형 | 단순 선형 | 단순 선형은 실제 분포에서 대다수를 왼쪽 끝에 뭉치게 하고 화면의 85%를 비운다 |
| 표시 방식 | 전체 화면 전환 | 시트 확대 / 보드를 메인으로 | 매일 여는 화면이라 시트가 맞지 않되, 아케이드 셸 은유는 남긴다 |
| 배치 계산 위치 | `ArcadeCore` 순수 함수 | 뷰 안에서 계산 | `ArcadeUI`에 테스트 타깃이 없다. 후속 항목 §3.1의 권고를 따른다 |
| 전이 XP | 동기화 트리거로 diff가 만들게 | 전이 성공 시 직접 부여 | 점수가 관측 로그의 순수 함수라는 불변식을 지킨다. 재집계 결과가 달라지지 않는다 |
| 실행 취소 | 5초 대기 후 요청 | 즉시 요청 후 되돌리기 전이 | 팀원의 Jira 알림에 왕복 기록을 남기지 않는다 (v0.1 스펙 §8.5) |
| 전이 거부 사유 | 버리고 Jira 링크로 대체 | 사유를 화면에 표시 | `transitionRejected(reason:)`가 Jira 응답 본문을 담고 그 안에 이메일이 섞일 수 있다(v0.1 스펙 §8.4). 사유를 채울 수 있는 곳은 어차피 Jira다 |
| raid 표현 | boss 색 + 채운 배경 | raid 전용 색 토큰 신설 | 팔레트는 대비 테스트로 확정됐다. 색 대신 구조로 가르는 것이 이 프로젝트의 기존 판단이다 |
