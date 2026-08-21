# OAuth 2.0 (3LO) 도입 검토

**결론: 지금은 도입할 수 없다. API 토큰 방식을 유지한다.**

기술적 선호의 문제가 아니라 **Atlassian이 데스크톱 앱을 지원하지 않기 때문**이다.
재검토 시점은 아래 §5에 조건으로 남긴다.

---

## 1. 왜 검토했나

현재 Jirarcade는 사용자가 Atlassian에서 API 토큰을 발급받아 붙여넣는 방식으로 로그인한다.
OAuth 2.0 3LO가 일반적으로 더 나은 이유는 셋이다.

- **자격증명을 앱이 보관하지 않는다.** 사용자는 브라우저에서 Atlassian에 직접 로그인하고,
  앱은 스코프가 제한된 토큰만 받는다.
- **자동 갱신된다.** refresh token으로 사용자 개입 없이 이어진다.
- **UX가 낫다.** "토큰을 발급받아 복사해 붙여넣기"가 아니라 "로그인 버튼 누르기"다.

## 2. 왜 안 되나

### 2.1 client secret이 필수이고 PKCE가 없다

Atlassian의 authorization code flow는 토큰 교환 시 `client_secret`을 요구한다.
데스크톱 앱은 그 값을 안전하게 보관할 수 없다 — 앱 번들에 넣으면 바이너리에서 추출된다.

이 문제를 푸는 표준이 PKCE(RFC 7636)이고, 그래서 public client가 secret 없이 인가를 받는다.
**Atlassian은 아직 지원하지 않는다.**

- `ECO-283`(PKCE 지원 요청): **Gathering Interest**, 미해결. 마지막 업데이트 2026-07-27, 55표.
  "needs more unique domain votes and comments before being reviewed by our team."
- PKCE로 시도하면 Jira가 client secret을 요구하며 요청을 막는다는 보고가 있다(`OAUTH20-2491`).

### 2.2 Atlassian이 명시적으로 인정하고 있다

공식 문서의 문장이다.

> "OAuth 2.0 (3LO) currently supports the code grant flow only. It does not support the implicit
> grant flow. We understand that this is **preventing people from using OAuth 2.0 (3LO) for
> standalone mobile apps** and web/JavaScript (Chrome, Electron) apps..."

Jirarcade는 정확히 이 범주(standalone native app)에 속한다.

### 2.3 제안된 워크어라운드는 지금보다 나쁘다

Atlassian이 ECO-283에서 제시하는 우회책은 이것이다.

> "each user generates their own client id & secret, stores it in their local environment,
> and then your app can mediate the authorization code flow using those unique credentials."

사용자가 developer console에서 **OAuth 앱을 직접 등록**하고, 스코프를 고르고, 콜백 URL을
설정하고, client id와 secret을 복사해 와야 한다. 지금의 "API 토큰 하나 발급받아 붙여넣기"보다
단계가 훨씬 많다. OAuth를 도입하는 이유가 UX 개선인데 UX가 나빠진다.

## 3. 두 방식 비교

| | API 토큰 (현재) | OAuth 2.0 3LO |
|---|---|---|
| 데스크톱 앱에서 가능한가 | **가능** | **불가** (secret 필수, PKCE 없음) |
| 자격증명 보관 | 앱이 Keychain에 보관 | 앱은 액세스/리프레시 토큰만 |
| 만료 | **최대 1년**, 수동 재발급 | 자동 갱신(rotating refresh, 90일 무활동 시 만료) |
| 권한 제한 | scoped token으로 가능 | 스코프로 가능 |
| 사용자 최초 설정 | 토큰 발급 → 붙여넣기 | (워크어라운드 시) OAuth 앱 등록 → id/secret 붙여넣기 |
| 취소 | 사용자가 개별·일괄 취소 | 사용자가 앱 접근 취소 |

권한 제한은 이미 동등하다. Jirarcade는 scoped API token을 지원하고
(`ScopedAPITokenAuth`), `read:jira-user` / `read:jira-work` / `write:jira-work`만 요구한다.

## 4. 코드는 이미 준비돼 있다

전환 비용은 낮게 유지되고 있다. `AuthProvider`가 **헤더뿐 아니라 baseURL까지** 추상화하기
때문이다.

```swift
public protocol AuthProvider: Sendable {
    var baseURL: URL { get }
    func authorize(_ request: inout URLRequest) async throws
    /// 401을 만났을 때 자격증명을 갱신할 수 있으면 true. 갱신 후 호출부가 요청을 재시도한다.
    func recoverFromUnauthorized() async throws -> Bool
}
```

- `baseURL`이 프로토콜에 있는 이유가 OAuth다. Basic auth는 `{site}/rest/api/3`을,
  OAuth 3LO는 `api.atlassian.com/ex/jira/{cloudId}/rest/api/3`을 쓴다.
- **그 URL은 이미 쓰이고 있다.** scoped API token이 같은 경로를 요구해서
  `ScopedAPITokenAuth`가 이미 구현돼 있고, `resolveCloudId()`도 있다.
- `recoverFromUnauthorized()`가 토큰 갱신 지점이다. API 토큰 구현은 `false`를 돌려주지만,
  OAuth 구현은 여기서 refresh를 돌리면 된다. `JiraClient`의 재시도 로직은 그대로다.

즉 OAuth가 가능해지면 **`AuthProvider` 구현 하나를 더하고 로그인 화면을 바꾸는 것**이
작업의 대부분이다. `JiraClient`와 모든 호출부는 손대지 않는다.

## 5. 재검토 조건

다음 중 하나가 참이 되면 다시 본다.

1. **`ECO-283`이 해결된다** (PKCE / public client 지원). 이것이 주 조건이다.
2. Atlassian이 native app을 위한 다른 인가 경로를 공식화한다.
3. Jirarcade가 **웹이나 서버 컴포넌트를 갖게 된다.** 그 경우 secret을 서버에 둘 수 있으므로
   제약이 사라진다. 팀 배포를 하더라도 데스크톱 전용이면 상황은 같다 —
   "여러 명이 쓴다"가 아니라 "secret을 둘 곳이 있다"가 기준이다.

## 6. 그동안 할 일 — 1년 만료 대응

OAuth를 못 쓰는 것과 별개로, **API 토큰의 1년 만료는 실제로 사용자를 막는다.**

Atlassian은 2024-12-15부터 새 토큰을 기본 1년 만료로 발급하고, 2025-03-13부터는 그 이전에
만든 토큰에도 1년 만료를 적용했다. 즉 **모든 사용자가 언젠가 만료를 맞는다.**

현재 동작은 401을 받으면 `.expired`로 가서 재입력을 요구하는 것이다. 동작 자체는 맞지만
두 가지가 아쉽다.

- **미리 알려줄 수 없다.** 토큰 발급일을 앱이 알 방법이 없어 "30일 뒤 만료됩니다"를 띄울 수 없다.
  사용자는 어느 날 갑자기 로그인 실패를 만난다.
- **재발급 경로가 화면에 없다.** `.expired` 화면에서 Atlassian 토큰 관리 페이지로 가는 링크를
  주면 재설정이 한 단계 짧아진다.

후자는 작은 작업이고 효과가 분명하다. 전자는 사용자가 만료일을 직접 입력하게 하지 않는 한
불가능하므로, 하지 않는다.

---

## 참고

- [OAuth 2.0 (3LO) apps](https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/)
- [ECO-283: PKCE 지원 요청](https://jira.atlassian.com/browse/ECO-283) — Gathering Interest
- [OAUTH20-2491: PKCE 표준 미준수](https://jira.atlassian.com/browse/OAUTH20-2491)
- [API 토큰 관리](https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/)
