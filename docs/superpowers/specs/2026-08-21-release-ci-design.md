# Jirarcade 릴리즈 CI/CD 설계

- 작성일: 2026-08-21
- 상태: 확정 (구현 계획 작성 대기)
- 선행: `docs/superpowers/specs/2026-08-14-app-shell-design.md` (앱 셸)
- 대상: GitHub Actions · macOS 26 러너 · Swift 6.2

---

## 1. 배경과 범위

저장소에 CI가 하나도 없다. `.github/`가 없고 태그도 0개다. 439개 테스트가 로컬에서만 돌고,
배포용 `.app` 번들은 `scripts/make-app.sh`를 사람이 손으로 실행해 만든다.
그 스크립트는 버전을 `0.1`/`1`로 하드코딩하고 있어서, 릴리즈마다 사람이 파일을 고쳐야 한다.

이 계획은 둘을 만든다.

| | 범위 | 트리거 |
|---|---|---|
| **검증 CI** | 빌드 + 439개 테스트 | PR · main 푸시 |
| **릴리즈 CD** | 테스트 게이트 → 유니버설 빌드 → 번들 → zip → GitHub Release | `v*` 태그 푸시 |

### 1.1 배포 조건

수령자는 소수이고 **Apple Developer 계정이 없다.** 따라서 Developer ID 서명도 공증(notarization)도
할 수 없고, ad-hoc 서명(`codesign --sign -`)을 유지한다. 받는 사람은 첫 실행 전에 격리 속성을
손으로 한 번 떼야 한다(§5).

이 제약은 설계를 바꾸지 않고 **한 곳으로 몰아둔다.** 나중에 계정이 생기면 서명 단계 한 곳에
identity를 넣고 그 뒤에 공증·stapling을 붙이면 된다(§6.3).

### 1.2 이 계획에서 새로 결정한 것

- **번들 생성 지식의 소재** — `make-app.sh`를 CI가 호출하는 단일 진실로 승격한다(§2)
- **버전의 출처** — git 태그 하나. Info.plist 하드코딩을 걷어낸다(§3.2)
- **툴체인 고정 정책** — 검증 CI와 릴리즈 CD가 서로 반대로 간다(§4.3)
- **출하 전 자체 검증** — 조용히 깨지는 실패를 업로드 전에 잡는다(§4.4)

---

## 2. 접근: `make-app.sh`를 단일 진실로

번들을 만드는 지식 — Info.plist 구성, `NSPrincipalClass`가 필요한 이유, ad-hoc 서명이
Keychain identity를 안정시킨다는 사실 — 은 현재 전부 `scripts/make-app.sh`에 주석과 함께 있다.

이 지식을 워크플로 YAML로 옮기거나 복제하지 않는다. 스크립트를 파라미터화하고 CI는 호출만 한다.

**이유:** 로컬 실행 경로와 릴리즈 경로가 같은 코드가 된다. `./scripts/make-app.sh`로 로컬에서
재현한 것이 곧 릴리즈 산출물이므로 "CI에서만 나는 실패"가 구조적으로 생기지 않는다.
Info.plist가 두 곳에 존재하다 한쪽만 고쳐지는 드리프트도 없다.

### 2.1 검토했지만 택하지 않은 것

**워크플로 YAML에 번들 로직 인라인.** 작성은 빠르지만 Info.plist가 두 벌이 된다.
이 저장소가 모듈 의존 방향을 테스트로 강제하는 곳(`ModuleBoundaryTests`)인 것과 결이 맞지 않는다.

**`.xcodeproj` 도입 + `xcodebuild archive`.** 정식 아카이브·서명 파이프라인이라 나중에 공증과
App Store까지 자연스럽게 이어진다. 다만 지금 SPM만으로 되는 일에 프로젝트 파일이라는 큰 상태를
더하는 것이고, 공증 계획이 없는 지금은 YAGNI다. 번들 생성 지점이 스크립트 한 곳에 모여 있으므로
나중에 옮기는 비용은 크지 않다.

---

## 3. `scripts/make-app.sh` 변경

### 3.1 인터페이스

```
./scripts/make-app.sh [옵션]
  --version <x.y.z>          CFBundleShortVersionString   (기본: 0.0.0)
  --build <n>                CFBundleVersion              (기본: 0)
  --config <debug|release>   빌드 구성                     (기본: debug)
  --universal                arm64 + x86_64               (기본: 호스트 아키텍처만)
  --output <dir>             번들을 놓을 디렉터리            (기본: .build)
  --open                     생성 후 실행
```

기본값은 현재 동작과 같다. 인자 없이 `./scripts/make-app.sh --open`을 실행하면 지금과 똑같이
debug·호스트 아키텍처로 만들고 띄운다. README에 적힌 사용법이 깨지지 않는다.

알 수 없는 옵션은 즉시 실패시킨다. 조용히 무시하면 CI에서 `--version`이 오타났을 때
`0.0.0`이 릴리즈로 나간다.

### 3.2 버전의 출처

| 키 | 릴리즈 | 로컬 |
|---|---|---|
| `CFBundleShortVersionString` | 태그에서 `v`를 뗀 값 (`v0.2.0` → `0.2.0`) | `0.0.0` |
| `CFBundleVersion` | `github.run_number` (단조 증가) | `0` |

**둘 다 0이면 "CI가 만들지 않았다"**는 규칙이 선다. 지금은 로컬 실험 빌드도 Info.plist에
`0.1`이라고 적어서 릴리즈된 0.1과 구분되지 않는다.

Info.plist 히어독을 변수 확장 모드로 바꾼다(`<<'PLIST'` → `<<PLIST`). plist 본문에
`$`·백틱이 없음을 확인했다. `PlistBuddy`/`plutil` 사후 주입도 가능하지만 도구 의존과
실패 모드만 늘고 얻는 것이 없다.

### 3.3 바이너리 경로를 추측하지 않는다

유니버설 빌드는 산출물을 **다른 디렉터리에 놓는다.** 실측:

```
유니버설:  .build/apple/Products/Release/JirarcadeApp     → lipo -archs: x86_64 arm64
단일:      .build/arm64-apple-macosx/release/JirarcadeApp
```

현재 스크립트가 하드코딩한 `.build/${CONFIG}/JirarcadeApp`은 SwiftPM이 만들어주는
`.build/release` 심볼릭 링크에 기대는 경로다. 유니버설 빌드에서는 그 링크가 가리키는 곳에
바이너리가 없어서 `✗ 실행 파일을 찾을 수 없습니다`로 죽는다.

빌드 인자를 배열로 한 번 만들어 두 곳에 **같은 배열**을 넘긴다:

```bash
BUILD_ARGS=(--product JirarcadeApp -c "$CONFIG")
[[ -n "$UNIVERSAL" ]] && BUILD_ARGS+=(--arch arm64 --arch x86_64)

swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
```

인자가 한쪽에만 붙는 순간 경로가 갈라지므로, 배열을 공유하는 것 자체가 그 버그를 막는다.

### 3.4 codesign 실패를 삼키지 않는다 (기존 동작 변경)

현재는 실패를 안내 문구로 바꾼다:

```bash
codesign --force --sign - "$APP" 2>/dev/null || echo "  (서명 생략 — ...)"
```

ad-hoc 서명은 인증서가 필요 없어서 실패할 이유가 사실상 없다. 그런데도 실패했다면 진짜
문제가 있는 상황이고, 삼키면 서명 없는 `.app`이 조용히 릴리즈된다. 실패시키고
`codesign --verify --strict`로 확인까지 한다.

로컬에서도 실패하는 편이 낫다. 서명이 없으면 Keychain이 매 실행마다 자격증명을 다시 묻는데,
그 원인이 여기라는 것을 지금은 알 방법이 없다.

### 3.5 스크립트가 하지 않는 것

**zip은 워크플로가 만든다.** 스크립트의 책임은 "번들을 만든다" 하나로 유지한다. 압축은
`ditto -c -k --sequesterRsrc --keepParent` 한 줄이고 재현에 변수가 없어서, 스크립트 안에
넣어봐야 인터페이스만 넓어진다.

`zip -r`이 아니라 `ditto`인 이유: `zip`은 심볼릭 링크와 확장 속성을 온전히 보존하지 못해
압축을 푼 `.app`의 codesign 서명이 깨진다. macOS 앱 배포에서 "빌드는 됐는데 받은 사람 쪽에서만
손상됐다고 나온다"의 흔한 원인이다.

---

## 4. 워크플로

### 4.1 `.github/workflows/ci.yml` — 검증

| 항목 | 값 |
|---|---|
| 트리거 | `pull_request`, `push: [main]` |
| 러너 | `macos-26` |
| working-directory | `Packages/Jirarcade` |
| 단계 | checkout → `swift --version` 로그 → `swift build --build-tests` → `swift test` |
| concurrency | 브랜치별 그룹, `cancel-in-progress: true` |

패키지가 리포 루트가 아니므로 `defaults.run.working-directory`를 지정한다.

**캐시는 넣지 않는다.** `Package.swift`에 외부 의존이 하나도 없어 받아올 것이 없고,
`.build` 캐싱은 툴체인·경로가 조금만 달라져도 무효화된다. 그때 생기는 "캐시 때문에 이상하게
깨진 빌드"를 디버깅하는 비용이 절약되는 몇 분보다 크다. 빌드가 실제로 느려지면 그때 넣는다.

### 4.2 `.github/workflows/release.yml` — 릴리즈

| 항목 | 값 |
|---|---|
| 트리거 | `push: tags: ['v*']` |
| 권한 | `contents: write` (그 외 차단) |
| 러너 | `macos-26` + Xcode 명시 핀 |

흐름:

1. **태그 형식 검증** — `v<major>.<minor>.<patch>` 또는 `v<x.y.z>-<prerelease>` 정규식.
   안 맞으면 즉시 실패한다. `v0.2` 같은 것을 실수로 밀면 `CFBundleShortVersionString`에
   그대로 들어가 나중에 조용히 이상하게 동작한다. 빌드 후가 아니라 10초 안에 죽는 편이 낫다.
2. **`swift test` 게이트** (§4.5)
3. `./scripts/make-app.sh --version <v> --build ${{ github.run_number }} --universal --config release`
4. `ditto`로 `Jirarcade-<version>.zip` 생성
5. **출하 전 자체 검증** (§4.4)
6. `gh release create` — 태그에 `-`가 있으면 `--prerelease`

`-`가 들어간 태그를 자동으로 prerelease로 처리하는 것이 §7.3의 리허설을 안전하게 만든다.
prerelease는 "최신 릴리즈" 자리를 차지하지 않는다.

### 4.3 툴체인 고정: CI와 릴리즈가 반대로 간다

두 워크플로는 툴체인에 대해 서로 다른 것을 원한다.

| | 원하는 것 | 방식 |
|---|---|---|
| 검증 CI | "미래에 깨지나?" | 러너 기본 Xcode + `swift --version` 로그 |
| 릴리즈 CD | "어제와 같은가?" | `sudo xcode-select -s`로 명시 핀 |

CI가 기본 Xcode를 쓰면 러너 이미지의 툴체인 상향을 릴리즈 전에 먼저 만난다.
릴리즈는 핀을 박고, 핀 경로가 사라지면 즉시 실패한다 — 조용히 다른 버전으로 빌드되는 것보다 낫다.

`macos-26`은 현재 GA다. **기본 Xcode는 실측 결과 26.6(Swift 6.3.3)이며, 개발 환경(Swift
6.2.3 / Xcode 26.2)과 이미 어긋나 있다** — 26.2는 `/Applications/Xcode_26.2.app`에 별도로
설치돼 있어 릴리즈 워크플로가 명시적으로 골라야 한다. `macos-latest`는 쓰지 않는다. 지금은
`macos-26`을 가리키지만 언젠가 조용히 움직인다.

`Package.swift`의 `platforms: [.macOS(.v15)]`가 배포 타깃을 결정하므로, macOS 26 러너에서
빌드해도 산출물은 macOS 15에서 동작한다. 러너 OS와 지원 OS는 다르다.

### 4.4 출하 전 자체 검증

유니버설 빌드와 서명은 **조용히 실패하는 종류**다. 빌드는 성공하고 zip도 만들어지는데
arm64 슬라이스만 들어있거나 서명이 깨져 있을 수 있다. 업로드 전에 넷을 확인하고,
하나라도 어긋나면 릴리즈를 만들지 않는다.

| 확인 | 명령 | 막는 실패 |
|---|---|---|
| 두 아키텍처 존재 | `lipo -archs`에 `arm64`·`x86_64` 둘 다 | Intel 맥에서 안 켜지는 릴리즈 |
| 서명 유효 | `codesign --verify --deep --strict` | 서명 없는 번들 출하 |
| 버전 주입됨 | `plutil -extract CFBundleShortVersionString raw`가 태그와 일치 | 태그는 v0.3.0인데 앱은 0.0.0이라 주장 |
| 압축 왕복 | zip을 별도 디렉터리에 풀어 `codesign --verify` 재확인 | 압축이 서명을 깨뜨린 경우 |

마지막이 핵심이다. **사용자가 겪을 경로를 CI가 먼저 밟는다.**

### 4.5 릴리즈에서 테스트를 다시 도는 이유

중복처럼 보이지만 아니다. 태그는 임의의 커밋에 붙을 수 있다 — CI를 통과한 적 없는 커밋,
혹은 통과 후 force-push로 바뀐 커밋에도. "이 커밋이 CI를 통과했다"는 사실을 태그가
보증해주지 않는다. 게이트는 **릴리즈되는 바로 그 트리에서** 서야 의미가 있다.

---

## 5. 릴리즈 산출물과 설치 안내

산출물은 `Jirarcade-<version>.zip` 하나이고 안에 `Jirarcade.app`이 들어 있다.

설치 안내는 `.github/release-notes-header.md`에 두고 워크플로가 버전만 치환해 릴리즈 본문
맨 위에 붙인다. 그 아래에 GitHub이 자동 생성한 커밋·PR 목록이 온다.

YAML 안 히어독이 아니라 파일로 두는 이유: 이 안내가 바뀌면 그 자체가 리뷰 가능한 diff가 된다.

안내 내용:

```markdown
## 설치

1. `Jirarcade-x.y.z.zip`을 내려받아 압축을 풉니다
2. `Jirarcade.app`을 `/Applications`로 옮깁니다
3. 터미널에서 한 번 실행합니다:

       xattr -d com.apple.quarantine /Applications/Jirarcade.app

**3번이 왜 필요한가:** 이 앱은 Apple 공증(notarization)을 받지 않았습니다.
macOS는 인터넷에서 받은 미공증 앱에 격리 표시를 붙이고 실행을 막으면서
"손상되었기 때문에 열 수 없습니다"라고 말합니다 — 실제로 손상된 게 아니라
표시가 붙었을 뿐이고, 위 명령이 그 표시를 뗍니다.

요구 사항: macOS 15 이상 (Apple Silicon · Intel 모두)
```

---

## 6. 문서 갱신

### 6.1 README — 테스트 개수

"221개 테스트가 약 0.2초에 끝납니다"는 사실이 아니다. 실측 결과 **439개**가 0.8초에 통과한다.
백필 작업이 늘린 뒤 갱신되지 않았다.

### 6.2 README — 설치 섹션

현재 README에는 소스에서 빌드하는 방법만 있고 **받아서 쓰는 방법이 없다.** 릴리즈가 생기면
곧바로 어긋나는 상태다. "실행" 섹션 앞에 릴리즈 내려받기 경로를 추가하고, `xattr` 안내의
근거를 §5와 같은 이유로 적는다.

### 6.3 공증 확장 지점

`--sign-identity` 인자를 미리 만들지 않는다(YAGNI). 대신 `make-app.sh`의 서명 단계에 주석으로
남긴다 — Developer ID가 생기면 identity를 여기에 넣고, 그 뒤에 `notarytool submit --wait`와
`stapler staple`이 붙는다. 코드가 아니라 지도만 남긴다.

---

## 7. 검증 전략

CI 작업의 고질병은 "머지해봐야 안다"이다. 세 층으로 줄인다.

### 7.1 로컬에서 스크립트 검증

`make-app.sh`는 순수 셸이라 지금 바로 돌려볼 수 있다.
`--version 9.9.9 --build 42 --universal --config release`로 만들고 §4.4의 **네 명령을 그대로**
손으로 실행한다. 워크플로가 할 검증과 동일한 명령이므로, 여기서 통과하면 남는 불확실성은
러너 환경뿐이다.

기본값 회귀도 확인한다: 인자 없이 실행했을 때 debug·호스트 아키텍처·버전 `0.0.0`인지.

### 7.2 YAML 문법

`actionlint`가 설치돼 있으면 돌린다. 없으면 건너뛴 사실을 기록한다.

### 7.3 프리릴리즈 태그로 실제 리허설

`v0.0.1-rc.1`을 밀어 전체를 돌린다. `-`가 있으니 prerelease로 표시되어 "최신 릴리즈" 자리를
차지하지 않고, 확인 후 릴리즈와 태그를 지우면 깨끗하다. **이것만이 진짜 end-to-end 검증이다.**

확인 항목: zip이 첨부됐는지, 릴리즈 본문에 설치 안내와 자동 노트가 모두 있는지,
내려받아 압축을 푼 `.app`이 실제로 실행되는지.

---

## 8. 스코프 경계

### 포함

- `.github/workflows/ci.yml` — 빌드 + 테스트
- `.github/workflows/release.yml` — 태그 기반 릴리즈
- `.github/release-notes-header.md` — 설치 안내
- `scripts/make-app.sh` 파라미터화 (§3)
- README 갱신 — 테스트 개수, 설치 섹션 (§6)
- 프리릴리즈 태그 리허설 1회 (§7.3)

### 제외

- **공증·Developer ID 서명** — 계정이 없다. 확장 지점만 주석으로 남긴다
- **dmg 산출물** — zip 하나로 간다. 공증이 없으면 Gatekeeper 경고는 어차피 동일하다
- **swift-format 린트·경고 0 강제** — 새 도구 설정과 기존 코드 정리가 따라온다. 별도 작업
- **`.build` 캐시** — §4.1
- **nightly / main 푸시마다 빌드** — 태그가 진실이다
- **Homebrew cask** — 수령자가 소수다

---

## 9. 완성 정의

1. PR을 열면 `macos-26`에서 빌드와 439개 테스트가 돌고 결과가 PR에 보인다
2. 인자 없는 `./scripts/make-app.sh --open`이 변경 전과 동일하게 동작한다
3. `--universal --config release --version X`가 두 아키텍처를 가진 서명된 번들을 만들고,
   Info.plist의 버전이 `X`다
4. `v0.0.1-rc.1` 태그를 밀면 prerelease가 생기고 zip이 첨부되며, 본문에 설치 안내와
   자동 생성 노트가 모두 있다
5. 내려받아 압축을 푼 `.app`이 안내대로 실행된다
6. README의 테스트 개수가 실측과 일치하고 설치 섹션이 있다

---

## 10. 리스크

| | 리스크 | 대응 |
|---|---|---|
| 1 | **Intel 실행은 실물 검증 불가.** arm64 맥에서 x86_64 슬라이스를 만들 순 있어도 Rosetta 없이 못 돌린다. `lipo`는 "들어있다"만 보증하고 "켜진다"는 보증하지 않는다 | 남는 위험으로 문서에 명시. 수령자 중 Intel 사용자의 첫 실행이 유일한 확인 |
| 2 | **`gh release create`의 헤더 + 자동 노트 조합 동작.** `--notes-file`과 `--generate-notes`를 같이 넘겼을 때의 합쳐지는 방식이 불확실 | 확실한 대체 경로: `gh api .../releases/generate-notes`로 본문을 받아 헤더와 직접 합쳐 `--notes-file` 하나로 넘긴다 |
| 3 | **`macos-26` 러너의 Xcode 26.2 실제 설치 경로** 미확인 | 첫 CI 실행 로그로 확인한 뒤 릴리즈 워크플로의 핀 경로를 확정한다 |
| 4 | **러너 이미지 드리프트.** 기본 Xcode가 26.3+로 올라갈 수 있다 | §4.3 — CI가 먼저 만나 알려주고, 릴리즈는 핀으로 막는다 |
| 5 | **codesign 실패를 더 이상 삼키지 않는 변경**이 로컬 워크플로를 막을 수 있다 | ad-hoc 서명이 실패하는 상황은 사실상 없다. 실패한다면 그것이 알아야 할 정보다 |

---

## 11. 결정 기록

- **번들 지식은 `make-app.sh` 한 곳에.** YAML 복제는 Info.plist를 두 벌로 만들고,
  `.xcodeproj` 도입은 공증 계획이 없는 지금 YAGNI다
- **태그가 버전의 유일한 출처.** 하드코딩된 `0.1`/`1`을 걷어낸다.
  로컬 빌드는 `0.0.0`/`0`으로 "릴리즈가 아님"을 드러낸다
- **유니버설 빌드.** macos-26 러너는 arm64라 그냥 빌드하면 Intel 맥에서 아예 안 켜진다.
  macOS 15는 Intel을 여전히 지원한다. 빌드 시간 2배는 이 규모에서 몇 분 문제다
- **경로는 `--show-bin-path`로 조회.** 유니버설과 단일 아키텍처의 산출물 경로가 다르다(§3.3)
- **압축은 `ditto`.** `zip -r`은 확장 속성을 잃어 서명을 깨뜨린다
- **릴리즈에서도 테스트를 돈다.** 태그는 CI 통과를 보증하지 않는다(§4.5)
- **캐시 없음.** 외부 의존이 0개라 받아올 것이 없다
