# 과거 이력 백필 — 후속 항목

`feature/history-backfill` 브랜치가 남긴, **의도적으로 고치지 않은** 것들을 한곳에 모았다.
브랜치 진행 중 태스크 리포트 19개와 리뷰 12개에 흩어져 있던 항목을 병합·정리한 것이며,
브랜치 안에서 해결된 항목은 뺐다. 리뷰 파일 원본은 `.superpowers/sdd/2026-08-13-history-backfill/`에 있다.

## 이 브랜치가 만든 것

Jirarcade는 그때까지 **앱을 켜 둔 동안 관측한 전이만** 채점했다. 이 브랜치는 Jira의 changelog를
읽어 앱을 쓰기 전의 이력까지 소급해 XP·레벨에 반영하는 **백필**을 추가한다. 페이지 단위로
티켓을 훑으며 각 티켓의 changelog를 상태 전이로 번역하고(`ChangelogParser`), 중단되면 페이지
커서를 저장해 이어받고(`BackfillRun`), 같은 전이를 두 번 넣지 않도록 Jira의 `historyId`로 중복을
거른다. 워크플로 매핑에 없는 과거 상태명은 Jira의 상태 카탈로그(`statusCategory`)로 단계를
**추정**해 채점하되 그 추정을 따로 저장하고, 매핑 마법사에 후보로 띄워 사용자가 확정하거나
"채점하지 않음"으로 끌 수 있게 한다. 라이브 동기화가 이미 근사로 기록해 둔 전이는 백필이 온전히
복원한 티켓에 한해 **대체**되어 이중 계상되지 않는다. XP는 통산과 시즌(30일) 두 벌로 집계되며,
같은 이벤트가 두 집계에서 같은 점수를 받도록 채점 파이프라인은 통산 로그로 끝낸 뒤 마지막에만
범위를 자른다.

---

## 1. 정확도·정합성

### 1.1 부분 복원 목록을 모으고 저장까지 하지만 아무도 보여주지 않는다

changelog가 잘린 채로 보충에 실패한 티켓은 `BackfillRun.partiallyRestoredKeys`에 쌓이고
`BackfillSnapshot.partiallyRestored`로 나오지만, `ArcadeApp`에도 `ArcadeUI`에도 **읽는 코드가 없다**
(`rg partiallyRestored Sources/ArcadeApp Sources/ArcadeUI` → 0건).

**언제 드러나는가** — 이력이 아주 긴 티켓이 있고 보충 조회가 실패했을 때. 사용자는 그 티켓이
온전히 소급됐다고 믿는데 실제로는 전이 일부만 들어가 있다. 게다가 잘린 changelog에서는
`ChangelogParser`가 `priorUpdatedAt`을 `issue.createdAt`부터 시작하므로 복원된 첫 전이의 정체
기준선이 티켓 생성 시각까지 밀려, **XP가 적게가 아니라 오히려 많게** 나올 수 있다(깨우기 배수 상한 4배).

**왜 지금 고치지 않았나** — 값은 전부 저장돼 있고 표시만 없다. 어떤 화면에 어떤 문구로 띄울지는
UX 결정이라 리뷰가 정할 일이 아니었다.

**고친다면** — `AppModel`에 `refreshDerivedState()`로 읽어 오는 프로퍼티 하나, `SettingsView`의
"과거 기록" 섹션에 정확도 경고(`backfillWasDegraded`) 옆에 한 줄. 값의 출처는
`ArcadeStore.backfillSnapshot`.

### 1.2 사이트 문자열로는 테넌트를 완전히 식별하지 못한다

계정 바인딩은 이제 `site + accountId`를 함께 본다. 그런데 사이트는 사용자가 **입력한 문자열**이다.
Atlassian은 커스텀 도메인을 지원하므로, 같은 테넌트를 두 이름으로 부를 수 있다.

**언제 드러나는가** — 같은 조직의 Jira를 커스텀 도메인으로 한 번, `*.atlassian.net`으로 한 번
로그인하면 **전환으로 오판되어 미러·이벤트 로그·워크플로 매핑이 지워진다.** 미러는 다시
동기화되지만 이벤트 로그는 복구되지 않는다. 반대 방향(다른 테넌트를 같은 이름으로)은 불가능하다.

**왜 지금 고치지 않았나** — 정답은 `cloudId`(테넌트의 정식 식별자, 호스트명과 무관하게 안정적)인데
지금은 스코프 토큰 폴백 경로에서만 조회한다. 항상 조회하면 실행마다 요청이 한 번 는다.
사이트 비교는 그 전보다 **좁은** 판정이고(그전에는 조직이 달라도 전환이 아니었다) 오판 조건이
좁아, 요청을 늘리는 결정은 따로 내리는 편이 맞다고 봤다.

**고친다면** — `AppModel.validate()`가 `resolveCloudId`를 항상 부르고 `AccountBinding`을
`v3|cloudId|accountId`로 넓힌다. `AccountBinding.init(rawValue:)`가 이미 버전 접두사로 갈리므로
`v2` 값은 사이트만 비교하는 지금 규칙으로 계속 다루면 된다(`v1`=옛 형식을 다루는 것과 같은 방식).

### 1.3 `refreshUnmapped()`가 사용자 매핑만 봐서 화면마다 개수가 다르다

`AppModel.refreshUnmapped()`는 `workflow.load()`(사용자 매핑)만 기준으로 세는데, 마법사의
`unscoredCount`는 폴백이 있는 상태를 뺀다. 그래서 플로어·캐비닛의 "⚠ 매핑되지 않은 상태 N개"
배지와 마법사가 서로 다른 숫자를 말한다.

**언제 드러나는가** — 백필이 폴백을 추정한 뒤 항상. 두 화면을 나란히 보면 보인다.

**왜 지금 고치지 않았나** — 원래는 **의도된 동작**이었다. 추정값을 확정으로 보여주면 사용자가
고칠 기회를 잃으므로 배지는 일부러 관대하게 셌다. 마법사가 폴백을 빼기 시작하면서 두 정의가
갈라진 것이고, 어느 쪽 정의를 정답으로 삼을지는 제품 판단이다.

**고친다면** — `refreshUnmapped(against:)`가 `effectiveWorkflow()`를 쓰게 하거나(배지가 마법사와
같아진다), 배지 문구를 "추정으로 채점 중 N개"로 나눠 둘 다 보여준다. `AppModel.swift:384`.

### 1.4 changelog에 없는 활동 때문에 백필의 정체 기준선이 라이브보다 이르다 — **의도적으로 수용한 근사**

> **결함이 아니다. 알고 받아들인 트레이드오프다. 버그로 착각해 고치려 들지 말 것.**

깨우기(wake) 배수는 티켓이 얼마나 오래 정체했는지로 계산되고, 정체 기준선은 "마지막으로 무언가
일어난 시각"이다. 라이브 경로는 Jira의 `updated`를 쓰므로 **댓글·워크로그도 기준선을 갱신**한다.
백필은 changelog만 보는데 changelog에는 댓글도 워크로그도 남지 않는다. 그래서 백필이 보는
정체 간격은 라이브보다 **항상 같거나 크고**, 소급 XP가 라이브보다 후하게 나온다.

**왜 받아들였나** — 댓글·워크로그를 티켓마다 따로 조회하면 백필 요청 수가 티켓당 2~3배가 된다.
1,264건 규모에서 감당할 값이 아니고, 편향의 방향이 "적게 준다"가 아니라 "많이 준다"라 사용자가
손해 보는 쪽이 아니다. `ChangelogParser`의 주석에 이 근사가 이미 문서화돼 있다.

**만약 정말 고쳐야 한다면** — 실물 백필 결과가 예상보다 크게 후할 때만 재검토한다. 방법은
티켓별 댓글·워크로그 조회를 백필에 더하는 것뿐이고, 요청 비용이 그 이유다.
(스펙 §11 리스크 1은 이와 **반대 방향**을 걱정하고 있다 — 그 서술도 함께 고쳐야 한다.)

### 1.5 시즌 요약의 `streak`가 통산 연속을 담는다 — **의도적으로 수용한 결정**

> **사용자 결정의 직접적 귀결이다. 버그가 아니다.**

"같은 이벤트는 통산과 시즌에서 같은 XP"를 지키려고 연속 배수를 통산 로그 한 번으로 계산하고
마지막에만 범위를 자른다. 그 결과 시즌 요약의 `PlayerSummary.streak`도 통산 연속 일수를 담는다.
현재 UI가 시즌 요약의 `streak`를 읽는 자리는 없다. HUD가 나중에 "시즌 연속"을 따로 보여주려 하면
그때는 `ScoreEngine.recompute`가 두 값을 따로 돌려주게 넓혀야 한다.

### 1.6 위생 데일리 보너스가 통산·시즌 양쪽에 각각 더해진다 — **설계대로**

두 재집계가 같은 미러를 보므로 같은 보너스(최대 50 XP)가 두 숫자에 각각 붙는다. 두 값은 서로
다른 범위의 합계이므로 이중 계상은 아니지만, 두 값을 나란히 보여줄 때 "시즌 XP + α = 통산 XP"가
성립하지 않는 원인 중 하나다. 확인만 해두고 손대지 않았다.

### 1.7 발견 목록 합집합은 영구히 누적되고 지울 방법이 계정 전환뿐이다

`discoveredStatuses()`가 모든 `BackfillRun`의 합집합을 돌려주도록 고친 것(리뷰 I1)의 직접적
귀결이다. Jira에서 이름이 바뀌거나 폐기된 상태도 마법사 후보에 영원히 남는다.
현재 규모(12건 안팎)에서는 문제가 아니다. 고친다면 미러에 실제로 존재하는 상태명으로 교차 필터.

### 1.8 `stopSyncing()`은 진행 중인 동기화를 취소하지 않는다

백필이 시작될 때 이미 들어가 있던 동기화 한 건은 그대로 끝까지 간다. 백필과 라이브 관측이
겹치는 창이 좁아졌을 뿐 완전히 닫히지는 않았다. 남은 창에서 이중 계상이 일어나도
`replaceObservedTransitions`가 다음 백필에서 정리한다. 완전히 닫으려면 스케줄러에 "진행 중인
동기화가 끝날 때까지 기다린다" 또는 백필 중 `requestSync`를 거부하는 게이트가 필요하다.

### 1.9 잘린 changelog를 파서가 감지하지 않는다 — 계약이 어디에도 적혀 있지 않다

`ChangelogParser.parse(issue:)`는 `JiraChangelogPage.isTruncated`를 보지 않는다. 보충 책임이
`BackfillEngine`에 있다는 것이 실제 설계이고 코드도 그렇게 동작하지만(`BackfillEngine.swift:281`),
그 **계약이 파서 쪽 어디에도 적혀 있지 않다.** 파서만 읽는 사람은 잘린 입력에서
`priorUpdatedAt` 체인과 마감일 시간축이 조용히 틀어진다는 것을 알 방법이 없다.
파서 doc-comment에 한 줄이면 닫힌다.

### 1.10 `resolve`의 맨몸 `catch`가 조직적 실패를 티켓 하나의 문제로 뭉갠다

보충 조회 중 토큰 만료(401)나 레이트 리밋이 나면 그 이후 잘린 티켓이 **전부** 조용히 "부분 복원"으로
기록되고 백필은 끝까지 돌아 정상 완료로 닫힌다. 결과에는 긴 `partiallyRestored` 목록만 남고
"이 티켓 하나가 404"와 "세션이 죽었다"를 구분할 방법이 없다. 취소(`CancellationError`)는 이미
구분해 다시 던진다 — 남은 것은 조직적 HTTP 실패다. `JiraError.unauthorized`·레이트 리밋을
`catch`에서 갈라 즉시 중단하면 되고, 자리는 `BackfillEngine.resolve`.

### 1.11 `nil` 토큰 미완료 run을 재개하면 진행 수가 총계를 넘는다

마지막 `advanceBackfill(nil)`과 `finishBackfill` 사이에 앱이 종료된 run을 재개하면 `repeat`-`while`
구조상 1페이지를 다시 요청한다. 총계 1,200에 `processed`가 1,202가 되어 진행률이 100%를 넘는다.
이벤트는 `historyId`가 막으므로 손상은 없다. 재현 조건이 두 저장 사이의 종료로 아주 좁다.

### 1.12 `fetchWholeChangelog`가 `startAt`을 `histories.count`로 민다

서버가 겹치는 페이지를 주면 카운트가 실제 오프셋과 어긋나 일부를 건너뛸 수 있다. 실무에서
확률이 낮고 `appendBackfillEvents`의 `historyId` 중복 검사가 이중 삽입은 막는다.
응답의 `startAt`을 그대로 믿고 밀면 구조적으로 없어진다.

---

## 2. 비결정성

### 2.1 "마지막 run" 조회 세 개가 `startedAt` 동률에서 비결정적이다

`lastBackfillFailure()`·`lastBackfillWasDegraded()`·`backfillSnapshot` 계열이 모두
`SortDescriptor(\.startedAt, order: .reverse)` + `fetchLimit 1`이다. 같은 `startedAt`을 가진 run이
둘 이상이면 어느 것이 나올지 보장되지 않는다.

**언제 드러나는가** — 프로덕션에서는 사람이 시작하는 동작이라 `Date()`가 서브밀리초로 갈려 사실상
안 겹친다. **문제는 테스트다** — clock을 고정한 테스트에서 run을 둘 만들면 비결정적이 된다.
이 브랜치에서 실제로 회귀 테스트 하나를 둘로 쪼개야 했고, 그 전에는 기존 테스트 하나가 정확히
이 이유로 틀린 구현을 통과시키고 있었다.

**왜 지금 고치지 않았나** — 스키마 변경(단조 증가 시퀀스 번호)이 필요하고, 이 브랜치는 이미
`BackfillRun`에 필드를 여러 개 더한 뒤였다.

**고친다면** — `BackfillRun`에 단조 증가하는 `sequence: Int`를 두고 정렬 키를
`(startedAt, sequence)`로. 앞으로 이 조회를 쓰는 테스트를 쓸 때는 run 두 개의 `startedAt`을
반드시 다르게 줄 것.

### 2.2 `ChangelogParser`의 `sorted`는 안정 정렬이 아니다

`ChangelogParser.swift:23`. Swift의 `sorted(by:)`는 안정성을 보장하지 않으므로 `createdAt`이 동일한
history 두 개의 출력 순서가 실행마다 뒤집힐 수 있다. `priorUpdatedAt`은 어차피 같은 값이고 중복
방지는 `historyId`로 하므로 **데이터는 틀어지지 않는다** — 배열 순서만 비결정적이다.
동률일 때 `historyId`로 타이브레이크하면 결정적이 된다.

---

## 3. 테스트가 지키지 못하는 것

### 3.1 `ArcadeUI`에 테스트 타깃이 없다 — 이 목록의 다른 여러 항목의 뿌리

`Package.swift`의 테스트 타깃은 `JiraKitTests`/`ArcadeCoreTests`/`ArcadeAppTests` 셋뿐이다.
뷰 배선(버튼이 무엇을 부르는가, `@State` 초기값, 조건부 분기)은 **소스 텍스트 검사로만** 지킬 수
있고, 그런 테스트는 이름이 주장하는 것을 실제로 검증하지 못한다.

이 브랜치에서 실제로 새어 나간 것:

- **마법사의 모순 방지 로직에 커버리지가 없다.** `WorkflowMappingView.binding(for:)`의 `.excluded`
  분기에서 `selection.removeValue(forKey:)`를 지우는 변이를 넣어도 **전체 테스트가 통과한다**(확인함).
  그 상태에서는 이미 단계를 지정한 상태를 "채점하지 않음"으로 바꿔도 Picker가 즉시 되튀고 저장된
  맵은 매핑 우선으로 계속 채점된다 — 리뷰 I3이 지적한 증상 그대로다.
  `theMappingWizardCanTurnAStatusOff`는 이름과 달리 소스 문자열 두 개의 존재만 grep한다.
- 설정 화면의 버튼 배선(`startBackfill()`을 실제로 부르는가)도 같은 이유로 무커버.

**왜 지금 고치지 않았나** — SwiftUI 뷰 타깃에 테스트를 붙이려면 뷰를 호스팅하거나 로직을 뷰
밖으로 내려야 한다. 둘 다 이 브랜치의 범위를 크게 넘는다.

**고친다면** — 분기 로직을 도메인으로 내리는 쪽이 값이 크다. 예: `RowChoice`(단계 지정 / 채점 안 함 /
미지정) 사이의 전이 규칙을 `ArcadeCore`의 순수 함수로 옮기면 `ArcadeCoreTests`가 잡는다.
뷰는 그 함수를 부르는 껍데기만 남는다.

### 3.2 `launchBackfill`의 배치 불변식이 테스트되지 않는다

`AppModel.launchBackfill`의 stop/defer 블록을 `guard backfillTask == nil` **앞으로** 옮겨도 전체
테스트가 통과한다(확인함). 코드는 옳고, 프로덕션에 동시 호출 경로가 사실상 없어 영향은 작다.
`isBackfilling` 도중 `launchBackfill`을 한 번 더 부르는 테스트 한 건이면 닫힌다.

### 3.3 이름이 주장하는 것보다 적게 검증하는 테스트들

| 테스트 | 실제로 고정하는 것 | 닫는 방법 |
|---|---|---|
| `simultaneousDueDateChangeUsesTheNewValue` | 기대값이 `issue.dueDate`(현재 값)와 같아, "바뀐 결과값을 썼다"와 "시간축을 무시하고 현재 값으로 폴백했다"를 구분하지 못한다 | 뒤에 duedate 변경을 하나 더 붙여 현재 값 ≠ 그 시점 값으로 만든다 |
| `anExplicitMappingSurvivesAContradictoryExclusion` | 주석은 "폴백 대비 우선순위"를 말하지만, 제외가 폴백을 **먼저** 걷어내므로 우선순위를 구분할 수 없다. 실제로는 "제외가 명시적 매핑을 무효화하지 않는다"만 고정한다 | 주석을 사실에 맞춘다. 우선순위 자체는 `BackfillIntegrationTests`가 이미 덮는다 |
| `mergingDoesNotMutateTheOriginal` | `merging`이 struct의 non-mutating 메서드라 **어떤 변이로도 실패시킬 수 없다** | 삭제하거나, 실제로 위험한 성질(같은 폴백으로 두 번 합쳐도 같은 결과)로 바꾼다 |
| `StatusCatalog`의 `if !label.isEmpty` 가드 | 픽스처에 빈 `name` 엔트리가 없어 **가드를 지워도 전체가 통과한다**(생존 변이). 동작 자체는 옳다(확인함) | 엔트리 하나짜리 테스트 |
| `BackfillEngineTests.swift:206`의 `#expect(events.count >= 2)` | 정확한 답이 2인데 부등호를 써, 엔진이 이벤트를 더 넣기 시작해도 통과한다 | `== 2` |
| `issueChangelog`·`statusCatalog`가 GET인지 | 어서션이 없다(`searchWithChangelog`만 메서드를 본다). `pageToken: nil`일 때 `nextPageToken` 키가 아예 빠지는지도 무커버 — 코드는 맞게 하고 있다 | 어서션 두 줄 |

### 3.4 헬퍼 이름 충돌

`ChangelogParserTests`의 `issue(...)`와 `ArcadeCoreTests/TestSupport.swift`의 top-level
`issue(key:status:...)`가 이름이 같다. 레이블이 달라 모호성은 없지만(컴파일 확인함) 백필 테스트가
늘면 헷갈릴 여지가 있다.

---

## 4. 죽은 코드·중복·비용

### 4.1 만들었지만 아무도 읽지 않는 것

- **`SyncOutcome`** — `summary`도 `newEvents`도 프로덕션 호출자가 없다. `AppModel`이 통산 요약을
  `refreshSummaries()`에서만 만들게 되면서 동기화 경로가 계산한 요약은 `ArcadeCoreTests`만 쓴다.
  타입 전체가 죽었다. 스펙상 계약일 수 있어 걷어내기 전에 확인이 필요하다.
- **`BackfillOutcome`** — 프로덕션이 읽는 필드는 `resolvedFallbacks` 하나뿐이다.
  `insertedEvents`·`processedIssues`·`discoveredStatuses`·`partiallyRestored`·`catalogUnavailable`은
  전부 스토어에서 다시 읽는 설계로 바뀌었다. 그렇다면 outcome이 들고 다닐 이유가 없다.
- **`ScoreEngine.recompute`의 `scored` 배열** — 프로덕션 호출자 두 곳이 모두 `.summary`만 쓰고
  버린다. 1,264건 × 3년 이벤트에서 **매 재집계마다** 만들어지는 배열이다. 반환 튜플을 나누거나
  `summary`만 돌려주는 오버로드를 두면 된다.
- **`BackfillSnapshot.discovered` / `.partiallyRestored`** — 엔진은 재개 시 이 둘을 쓰지 않는다
  (로컬에서 새로 모아 `advanceBackfill`이 합집합한다). 게다가 `snapshot.discovered`(그 run 하나)와
  `discoveredStatuses()`(전체 합집합)는 이름이 거의 같은데 의미가 다르다. `.partiallyRestored`는
  1.1을 고칠 때 쓰이므로 그것과 함께 정리하는 편이 낫다.

### 4.2 렌더링마다 디스크를 치는 계산

`AppModel.currentMapping`/`currentFallbacks`는 매 접근마다 `workflow.load()`/`loadFallbacks()`로
JSON을 파싱한다. `SettingsView.mappingSection`은 body마다 2회,
`WorkflowMappingView.unscoredCount`는 `allCandidates.count { ... model.currentFallbacks ... }` 안이라
**후보 한 건마다 1회**다. 후보 12건이면 body 한 번에 12회 + 행마다 1회씩 더. 한 번 읽어 지역
변수에 담으면 끝난다. 기존에도 행이 같은 패턴이었으나 이번에 호출 지점이 늘었다.

### 4.3 매 동기화마다 이벤트 전량을 두 번 재집계한다

`refreshSummaries()`가 통산·시즌 두 번 전량을 돈다. 1,264건 규모에서는 문제가 없지만 이벤트
로그는 append-only라 단조 증가한다. 언젠가 증분 집계나 캐시가 필요해질 자리다.

### 4.4 `yyyy-MM-dd` 포맷터가 세 곳에 중복

`ArcadeCore/Backfill/ChangelogParser.swift:106`, `JiraKit/ChangelogDTO.swift:188`,
`JiraKit/DTO.swift:142`. 설정이 문자 단위로 동일해(gregorian / en_US_POSIX / UTC) 지금은 같은 값을
만들지만, **한쪽만 고치면 조용히 갈라진다.** `ArcadeCore` 쪽은 `static let`으로 재사용하고
`JiraKit` 쪽은 호출마다 새로 만든다 — 백필 규모에서 비용이 문제인 쪽은 `JiraKit`이다.

### 4.5 `finishSyncRun`은 여전히 크래시하는 패턴을 쓴다

`ArcadeStore.finishSyncRun`의 `context.model(for: id) as? SyncRunRecord`는 다른 스토어의 식별자를
받으면 nil이 아니라 **크래시한다** — `syncRunNotFound`는 사실상 도달 불가능한 케이스다.
백필 쪽(`backfillRun(for:)`)은 이 브랜치에서 fetch 헬퍼로 바꿨으므로 같은 모양으로 맞추면 된다.
실전에서는 같은 스토어의 식별자만 오가 현재 버그로 드러나지는 않는다.

---

## 5. JiraKit 경계

### 5.1 `approximateIssueCount` 디코딩 실패 문구에 응답 조각이 실릴 수 있다

`JiraClient.swift:87` — `JiraError.decoding(context: "approximateIssueCount: \(error)")`.
지금은 `BackfillEngine.approximateTotal`이 전부 삼켜 화면에 닿지 않으므로 실제 유출은 없다.
다만 `AppModel`이 다른 곳에서는 `.decoding`의 페이로드를 위험 취급하고 있으므로
(`AppModel.swift`의 사용자 메시지 생성부), 이 경로만 예외로 남는 것은 리팩터링 한 번 거리다.

### 5.2 `JiraClient`의 `invalidSite` guard는 도달 불가능하고 의미도 어긋난다

`JiraClient.swift:166`의 `guard let url = components?.url else { throw JiraError.invalidSite }`.
`URLComponents(url:resolvingAgainstBaseURL: false)`는 인자가 이미 `URL`이라 RFC 3986을 만족하고,
`auth.baseURL`은 `APITokenAuth.init`이 검증하며 `appendingPathComponent`는 퍼센트 인코딩한다.
즉 실행되지 않는다. 실행된다 해도 "사이트가 잘못됐다"가 아니라 경로/쿼리 조립 실패이므로
`invalidSite`는 오진이다. 테스트도 없다(있을 수도 없다).

### 5.3 `issueChangelog`의 `maxResults: 100` 하드코딩

`JiraClient.swift:64`. 호출자가 페이지 크기를 정하지 못한다. Jira 기본값과 같아 지금은 무해하지만,
보충 루프가 `startAt`을 밀 때 페이지 크기를 클라이언트 바깥에서 알 수 없다(응답의 `maxResults`를
봐야 한다). 파라미터로 올리면 끝난다.

### 5.4 `statusCatalog`은 항목 하나만 어긋나도 카탈로그 전체를 잃는다

`JiraStatusCatalogEntry.init(from:)`이 `id`/`name`/`statusCategory`를 모두 필수로 디코드한다.
Atlassian OpenAPI의 `StatusDetails`는 **required가 하나도 없다**(확인함). 실무상 `/status`가 이 셋을
빼먹는 일은 없지만, 한 건이라도 어긋나면 배열 전체 디코드가 실패해 스펙 §5의 폴백 ②가 통째로
죽는다. 스펙 §7이 "`/status` 조회 실패 → degraded 진행"을 정의해 두어 호출부가 흡수하긴 한다.
항목 단위로 실패를 건너뛰게 하면(`compactMap` + per-entry `try?`) 부분 손실로 줄어든다.

### 5.5 `BackfillRun.totalIssueCount`가 옵셔널이 아니다

엔진은 총계를 모를 때 `totalIssueCount ?? 0`으로 **0을 저장한다.** 진행률 콜백은 nil을 그대로
넘겨 화면이 불확정 스피너를 띄우지만, 재개 화면이 `BackfillSnapshot.totalIssueCount`를 읽어
진행률을 그리면 "1/0"이 된다. 지금 재개 화면은 저장된 총계를 쓰지 않아 드러나지 않는다.
쓰기 시작할 때 `Int?`로 넓혀야 한다(SwiftData 스키마 변경).

### 5.6 재개한 실행의 `BackfillOutcome`에는 이번 실행분만 담긴다

엔진은 재개할 때 `existing.discovered`/`existing.partiallyRestored`를 읽지 않고 새 카탈로그와 빈
배열로 시작한다. `advanceBackfill`이 `union`으로 합쳐 **DB에는 누적**되므로 현재 호출부
(스토어에서 다시 읽는다)는 영향받지 않는다. outcome만 보고 무언가를 결정하는 호출부가 생기면
그때 문제가 된다 — 4.1의 `BackfillOutcome` 정리와 함께 판단할 자리다.

### 5.7 `StatusCatalog`의 작은 것 둘

- `collect(label)`과 `fallbacks[label] = stage`가 **별도 크리티컬 섹션**이다. 동시 해석 중
  `unmappedNames`에는 들어갔지만 `resolvedFallbacks`에는 아직 없는 순간이 관찰될 수 있다.
  둘 다 누적 전용이고 백필이 끝난 뒤 읽히므로 실질적 영향은 없다(데드락도 없다).
  한 번의 `withLock`으로 합치면 깔끔하다.
- 이름이 같고 ID가 다른 두 엔트리는 `fallbacks`에서 **나중 것이 이긴다.** 실제 Jira에서 드물고
  `byId`가 ID 중복은 이미 처리한다.

### 5.8 `ParsedTransition`이 `public`인데 memberwise init은 internal

`ChangelogParser.swift:6-11`. `JiraKit` DTO 네 개를 열어 준 것과 정확히 같은 함정이 새 타입에
그대로 있다. 지금은 `@testable import ArcadeCore`라 문제가 없지만 `ArcadeApp`/`ArcadeUI`에서
픽스처로 만들 일이 생기면 같은 오류가 난다.

### 5.9 `WorkflowStore` 프로토콜이 폴백까지 떠안았다

폴백 저장은 백필만 쓰는데 모든 구현이 채워야 한다. 지금은 구현이 둘뿐이라 문제없다.
구현이 더 늘면 별도 프로토콜로 쪼개는 편이 낫다.

또한 **폴백 로드 실패를 아무도 다루지 않는다.** `FileWorkflowStore.read`는 손상된 JSON에서
throw하고, 사용자 매핑 쪽은 그 에러를 "매핑 없음"과 구분해 경고를 띄우지만(`workflowSaveWarning`
계열) 폴백 쪽은 `try?`로 삼켜진다. 폴백은 추정값이므로 빈 폴백으로 degrade하는 지금 동작이
맞다고 보지만, 그 판단이 코드에 적혀 있지 않다.

---

## 6. 화면 전이

### 6.1 `RootView`의 재진입 조건과 그 주석의 전제가 두 겹 깨졌다

`Sources/ArcadeUI/RootView.swift:54`의 `new == .ready && old != .expired`는 "`.ready`는 최초 설정
직후에만 들어온다"는 전제로 쓰였고, 바로 위 주석이 그 전제 세 가지를 명시하며 "이 줄을 건드리기
전에 위 셋을 다시 확인할 것"이라고 경고한다. 그 전제가 이 브랜치에서 두 번 깨졌다.

1. 매핑 재진입(`.ready → .mappingWorkflow → .ready`)이 생겼다 — 매핑을 고칠 때마다 `startSyncing()`이
   `loopTask`를 취소·재생성해 **연속 실패 카운트와 백오프 지연이 리셋**되고, 쿨다운을 무시하는
   `syncNow(.manual)`이 한 번 더 나간다.
2. 백필이 끝날 때도 `startSyncing()`을 부른다 — 원래 돌던 루프를 되살리는 것이므로 동작은 맞지만,
   "`startSyncing()`을 부르는 곳은 이 한 곳뿐"이라는 전제가 깨졌다.

**동작이 깨지지는 않는다.** 매핑 변경 직후의 동기화 자체는 합리적이다. 문제는 **주석이 지키려던
불변식이 이미 거짓인데 주석은 그대로**라는 것이다 — 다음 사람이 그 주석을 믿는다.
주석을 사실에 맞추거나, 조건을 "최초 진입"을 정말로 판별하는 형태로 바꾸거나 둘 중 하나가 필요하다.

---

## 7. 확인만 하고 넘어간 것

### 7.1 `XpAwarder`의 3단 폴백 중 3단이 도달 가능한지 확인하지 못했다

`XpAwarder.swift:52`의 주석은 `issue.jiraUpdatedAt` 폴백을 "기준선 없이 기록된 옛 이벤트를 위한
최후 폴백"이라고 하는데, `priorUpdatedAt`이 nil인 `.statusChanged`/`.touched`가 실제로 생기는
경로가 지금 있는지 확인하지 못했다. **있다면** 그 이벤트는 미러 의존이 되어 "채점은 이벤트 로그의
순수 함수"라는 불변식을 벗어난다. `DiffEngine`을 손댈 때 함께 볼 만하다.
