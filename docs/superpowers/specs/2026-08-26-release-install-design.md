# Jirarcade 설치 경험 개편 — Homebrew cask · curl 설치 스크립트

- 작성일: 2026-08-26
- 상태: 확정 (구현 계획 작성 대기)
- 선행: `docs/superpowers/specs/2026-08-21-release-ci-design.md` (릴리즈 CI/CD)
- 대상: GitHub Actions · macOS 26 러너 · `ahngbeom/homebrew-tap`

---

## 1. 배경과 범위

### 1.1 지금 상태

릴리즈 파이프라인은 동작한다. 태그를 밀면 유니버설 번들이 만들어지고, 출하 전 검증을 통과한
zip이 릴리즈에 붙는다. 문제는 그 다음이다 — 받는 사람이 터미널을 열어야 한다.

    xattr -d com.apple.quarantine /Applications/Jirarcade.app

이 안내는 `.github/release-notes-header.md`와 README에 있다. 압축 풀고, 옮기고, 명령을 치는
세 단계다. 앱이 "손상되었기 때문에 열 수 없습니다"라고 말한 직후에 사용자가 이걸 읽어야 한다.

### 1.2 전제가 바뀌었다

선행 설계문 §8은 Homebrew cask를 **"수령자가 소수다"**라는 이유로 제외했다. 배포 대상이
개발자 대상 공개 배포로 바뀌면서 이 전제가 무효가 됐다. 이 문서가 그 결정을 뒤집는다.

같은 문서 §6.3의 **"공증 확장 지점은 코드가 아니라 지도만 남긴다"**는 결정은 유지한다(§6.2).

### 1.3 이 설계에서 새로 결정한 것

- 배포 채널: Homebrew cask(주) + curl 설치 스크립트(보조), 릴리즈 zip은 그대로 유지
- 무결성 보증: Gatekeeper 대신 sha256 — 릴리즈 자산과 cask가 **같은 해시 하나**를 공유
- tap 갱신 주체: 릴리즈 워크플로가 `ahngbeom/homebrew-tap`에 직접 push
- 공증: 이번 범위 밖. 무료 경로로 완결하되 구조가 나중에 끼워넣기를 막지 않게 한다

---

## 2. 접근: 자산 하나, 체크섬 하나, 채널 둘

```
태그 v* push
  └─ release.yml
      ├─ 테스트 게이트 → make-app.sh → verify-bundle.sh   (기존)
      ├─ ditto → Jirarcade-<v>.zip                        (기존)
      ├─ shasum -a 256 ──────────┬─────────────────┐
      ├─ make-cask.sh ───────────┘                 │      (신규)
      │     └─ Casks/jirarcade.rb (버전·sha256 주입)│
      ├─ 릴리즈 공개: zip + zip.sha256 자산  ◄──────┘      (자산 1개 추가)
      │
      └─ [별도 job] tap push → 설치 스모크(brew · curl)    (신규)
```

sha256을 **한 번만** 계산해 cask와 릴리즈 자산 양쪽에 주입한다. cask가 자기 해시를 따로
계산하고 install.sh가 또 따로 계산하면, 언젠가 둘이 다른 zip을 가리켜도 아무도 모른다.
`verify-bundle.sh`가 릴리즈 워크플로와 같은 `ditto` 플래그를 쓰도록 주석으로 못박아둔 것과
같은 종류의 방어다.

### 2.1 검토했지만 택하지 않은 것

| 대안 | 이유 |
|---|---|
| **tap 리포가 릴리즈를 감지해 스스로 갱신** | cask 갱신 실패가 릴리즈와 분리돼 조용히 실패한다. 사용자는 `brew upgrade`가 새 버전을 안 준다는 사실로만 알게 된다 |
| **cask 수동 갱신** (`cc-menutor` 방식) | 시크릿이 필요 없지만, 잊으면 tap이 뒤처진다. `brew upgrade`를 주 경로로 삼은 결정과 충돌한다 |
| **`--no-quarantine` 안내** | Homebrew 6.x에서 이 플래그가 **제거**됐다(실측: `Error: invalid option: --no-quarantine`). 미서명 cask에 남은 경로는 `postflight` + `xattr`뿐이다 |
| **dmg 산출물** | 공증이 없으면 Gatekeeper 동작은 zip과 동일하다. 선행 설계문의 판단을 유지한다 |
| **Sparkle 등 앱 내 자동 업데이트** | `brew upgrade`가 업데이트 경로를 이미 제공한다. 앱 코드에 의존성과 서명 요구가 따라온다 |
| **소스 빌드 formula** | Xcode 툴체인을 요구해 "간편한 설치"라는 목적과 어긋난다 |

---

## 3. `scripts/install.sh` (신규)

### 3.1 인터페이스

```
curl -fsSL https://raw.githubusercontent.com/Ahngbeom/jirarcade/main/scripts/install.sh | sh
```

환경 변수 하나를 받는다.

| 변수 | 기본 | 용도 |
|---|---|---|
| `JIRARCADE_VERSION` | 최신 안정판 | 특정 버전 고정. 프리릴리즈 설치의 유일한 경로이기도 하다(§5.5) |

### 3.2 quarantine이 붙지 않는 것이 이 설계의 전제다

`curl | sh`가 여기서 정당한 이유는 편의가 아니다. quarantine 확장 속성은 파일을 내려받은
**프로세스가** 붙인다 — `LSFileQuarantineEnabled`를 선언한 앱(브라우저·메일·AirDrop)만
해당된다. `curl`은 선언하지 않으므로 격리 딱지가 애초에 생기지 않는다.

즉 이 스크립트는 Gatekeeper 우회가 아니라 다른 경로다. 기존 안내의 `xattr -d`가 사라지는
것도 명령을 숨겨서가 아니라 **뗄 딱지가 없어서**다.

### 3.3 무결성은 스스로 만들어야 한다

`curl | sh`는 Gatekeeper의 보증을 받지 못한다. 그 자리를 sha256이 메운다. 릴리즈에 함께
올라간 `Jirarcade-<v>.zip.sha256`과 대조하고, **불일치하면 즉시 중단한다.**

파일은 `shasum -a 256`의 원본 형식(`<해시>␣␣<파일명>`)을 담고, 스크립트는 첫 필드만 뽑아
비교한다. `shasum -c`를 쓰지 않는 이유: 그쪽은 파일명까지 일치해야 하는데, 검증 시점의
임시 파일명은 릴리즈 자산명과 다를 수 있다.

이 검증이 없으면 스크립트는 "아무거나 받아서 실행"과 구별되지 않는다. 선택 사항이 아니다.

### 3.4 순서: 검증이 교체보다 먼저다

1. macOS인가 — 아니면 중단
2. `sw_vers -productVersion` 주 버전 ≥ 15 — `LSMinimumSystemVersion`과 같은 값
3. `pgrep -x JirarcadeApp` — 실행 중이면 종료를 안내하고 중단
4. `[ -w /Applications ]` — 쓰기 권한이 없으면 명확히 알린다
5. 버전 결정 — `JIRARCADE_VERSION` 또는 `releases/latest`(프리릴리즈·초안 자동 제외)
6. `curl -fL`로 zip과 `.sha256` 수신
7. **sha256 대조** — 불일치 시 중단
8. `ditto -x -k`로 임시 디렉터리에 전개 — `unzip`은 확장 속성을 잃어 서명을 깨뜨린다
9. **`codesign --verify --strict`** — 실패 시 중단
10. 교체: 기존 앱을 임시 위치로 옮기고 → 새 앱을 넣고 → 성공 시 옛것 삭제, 실패 시 되돌림
11. 설치 후 확인: `codesign --verify --strict` 재실행 + quarantine 속성 부재

7·9번이 10번보다 앞에 있는 것이 요점이다. 실패하면 기존 앱이 그대로 남는다.

10번은 디렉터리 교체라 진짜 원자적일 수 없다. 옛것을 먼저 옮기고 새것을 넣는 순서로
창을 좁히고, 실패 경로에서 되돌린다. 창을 0으로 만드는 것은 이 규모에서 과하다.

### 3.5 스크립트가 하지 않는 것

- **`sudo`를 부르지 않는다.** `/Applications`에 쓸 수 없으면 그 사실을 알리고 멈춘다.
  설치 스크립트가 조용히 권한을 올리는 것은 `curl | sh`에서 특히 나쁘다
- **`~/Applications` 폴백을 만들지 않는다.** 두 위치를 지원하면 제거·업그레이드 경로가
  둘로 갈라진다. 필요해지면 그때 만든다
- **제거 기능을 넣지 않는다.** `rm -rf /Applications/Jirarcade.app` 한 줄이다.
  cask 쪽은 `brew uninstall`과 `zap`이 이미 담당한다

---

## 4. `scripts/make-cask.sh` (신규)

워크플로 YAML이 아니라 스크립트로 둔다. `verify-bundle.sh`가 세운 원칙 — 로컬과 CI가 같은
코드를 돌아야 한다 — 을 따른다. 명령을 양쪽에 복사하면 그 동일성은 첫 수정에서 깨진다.

### 4.1 인터페이스

```
./scripts/make-cask.sh --version <x.y.z> --sha256 <해시> [--output <경로>]
```

`--output` 기본값은 표준 출력이다. 워크플로는 tap 체크아웃의 `Casks/jirarcade.rb`로
리다이렉트하고, CI 스모크는 임시 파일에 받아 `ruby -c`에 넘긴다. `make-app.sh`가 값이 필요한
옵션에 다른 옵션이 오는 것을 거부하는 것과 같은 인자 검사를 둔다 — CI에서 `--version` 오타가
조용히 잘못된 cask를 만드는 일을 막는다.

### 4.2 생성물

```ruby
cask "jirarcade" do
  version "0.2.0"
  sha256 "…"
  url "https://github.com/Ahngbeom/jirarcade/releases/download/v#{version}/Jirarcade-#{version}.zip",
      verified: "github.com/Ahngbeom/jirarcade/"

  name "Jirarcade"
  desc "macOS app that shows Jira tickets as an arcade game"
  homepage "https://github.com/Ahngbeom/jirarcade"

  depends_on macos: ">= :sequoia"
  livecheck { skip "Auto-generated on release." }

  app "Jirarcade.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Jirarcade.app"]
  end

  zap trash: [
    "~/Library/Application Support/Jirarcade",
    "~/Library/Preferences/dev.jirarcade.app.plist",
  ]

  caveats "Jira 자격증명은 Keychain의 'Jirarcade' 항목에 남습니다 — zap이 지우지 못합니다."
end
```

`livecheck` 생략과 `verified:` 표기는 같은 tap의 `dv.rb`를 따른다.

### 4.3 `postflight`가 `staged_path`가 아니라 `appdir`을 쓰는 이유

`dv.rb`는 `binary` cask라 산출물이 staged 상태로 남지만, `app` stanza는 번들을
`/Applications`로 **옮긴 뒤** postflight를 돌린다. `staged_path`를 쓰면 이미 비어 있는
경로에 `xattr`를 걸어 아무 효과 없이 성공한다.

### 4.4 `zap` 대상의 출처

코드에서 확인한 실제 경로다. 추측이 아니다.

| 경로 | 근거 |
|---|---|
| `~/Library/Application Support/Jirarcade` | `WorkflowStore.swift`·`SprintFieldStore.swift`의 `applicationSupport()` |
| `~/Library/Preferences/dev.jirarcade.app.plist` | `UserDefaults.standard` + `CFBundleIdentifier` |

Keychain의 `Jirarcade` 항목(`CredentialStore.swift`)은 cask가 지울 수단이 없다.
`caveats`로 알린다 — 조용히 남기는 것보다 낫다.

### 4.5 `depends_on macos: ">= :sequoia"`

`LSMinimumSystemVersion` 15.0과 같은 값이다. 두 곳이 어긋나면 cask는 설치를 허용하는데
앱이 안 켜진다. 이 값은 `make-app.sh`의 plist와 함께 움직여야 한다.

---

## 5. 워크플로

### 5.1 `release.yml` — 되돌릴 수 없는 일을 뒤에 둔다

기존 워크플로는 "초안 → 자산 업로드 → 공개" 순서로 이미 이 원칙을 따른다. 그대로 잇는다.

| 순서 | 스텝 | 실패하면 |
|---|---|---|
| 1–5 | 테스트·번들·검증·zip *(기존)* | 아무것도 나가지 않는다 |
| **6** | 체크섬 계산 + `make-cask.sh` + `ruby -c` | 아무것도 나가지 않는다 |
| 7–8 | 노트·초안 생성 — 자산에 `.zip.sha256` 추가 | 초안만 남는다 |
| 9 | 공개 *(기존)* | — |
| **10** | tap push + 설치 스모크 *(별도 job)* | 릴리즈는 살아있고 brew만 뒤처진다 |

cask 생성을 공개 **전**으로 당긴 것이 요점이다. `make-cask.sh`의 버그나 문법 오류는
릴리즈가 나가기 전에 죽는다.

### 5.2 tap 갱신을 별도 job으로 두는 이유

10단계는 되돌릴 수 없는 지점(공개) 뒤에 있어 완전히 막을 수 없다. 그래서 회복 경로를
설계에 넣는다 — 별도 job이면 "Re-run failed jobs"가 릴리즈를 다시 만들지 않고 tap 갱신만
재시도한다. 실패하지 않는 척하는 것보다 낫다.

커밋 메시지는 같은 tap의 관례를 따른다: `Brew cask update for jirarcade version v<x.y.z>`.

### 5.3 `ci.yml` — 태그를 밀기 전에 잡는 층

기존 "번들 스모크" 스텝과 같은 논리다. 새 스크립트도 태그 전까지 한 번도 돌지 않으면,
버그가 공개된 태그 위에서만 드러난다.

- `make-cask.sh`를 더미 버전·해시로 실행하고 `ruby -c`로 문법 검사
- `install.sh`는 `sh -n` 문법 검사 — 전체 실행은 실제 릴리즈가 있어야 가능하다

### 5.4 진짜 검증은 사용자 경로를 밟는 것이다

`verify-bundle.sh`의 압축 왕복 검사가 이미 이 발상이다. 설치 채널에 그대로 적용한다.
10단계 스모크는 러너에서 **실제 명령을 실행한다.**

- `brew install --cask ahngbeom/tap/jirarcade` → 앱 존재 · `codesign --verify --strict` ·
  **quarantine 속성 부재**
- `brew uninstall --cask` 후 `install.sh` 실행 → 같은 세 가지 확인

quarantine **부재**를 명시적으로 검사하는 것이 중요하다. postflight의 `xattr`가 조용히
실패해도 `brew install`은 성공으로 끝나고, 문제는 사용자가 앱을 더블클릭할 때 처음 드러난다.
`verify-bundle.sh`가 아이콘의 매직 넘버까지 확인하는 것과 같은 계열이다 — "명령이 성공했다"와
"결과가 옳다"는 다르다.

### 5.5 프리릴리즈는 tap을 갱신하지 않는다

기존 워크플로는 이미 프리릴리즈가 '최신 릴리즈' 자리를 차지하지 않게 한다. 같은 판단을
tap에도 적용한다 — `brew` 사용자는 안정판만 받는다.

따라서 프리릴리즈 태그에서는 brew 스모크를 돌릴 수 없다. 대신 curl 스모크를
`JIRARCADE_VERSION=<version>`으로 돌린다. §3.1의 환경 변수가 존재하는 이유가 이것이다.

### 5.6 `HOMEBREW_TAP_TOKEN` — 사람이 먼저 해야 하는 일

이 리포의 첫 시크릿이다. 워크플로가 다른 저장소에 push하므로 `github.token`으로는 안 된다.

- fine-grained PAT, 저장소 접근은 `ahngbeom/homebrew-tap` 하나만
- 권한은 **Contents: Read and write** 하나만
- `Ahngbeom/jirarcade`의 Actions secret으로 등록

**없으면 job이 명시적으로 실패한다.** 조용히 건너뛰면 릴리즈가 나가도 tap이 갱신되지 않은
것을 아무도 모른다. `make-app.sh`가 `codesign` 실패를 삼키지 않기로 한 것과 같은 판단이다.

---

## 6. 문서 갱신

### 6.1 설치 안내 교체

`README.md`와 `.github/release-notes-header.md`의 설치 절이 세 단계에서 두 줄이 된다.

```
brew install --cask ahngbeom/tap/jirarcade     # 업데이트: brew upgrade --cask jirarcade
curl -fsSL .../scripts/install.sh | sh         # Homebrew 없이
```

"공증을 받지 않았다"는 설명은 **남긴다.** 다만 성격이 바뀐다 — "그래서 이 명령을 치세요"가
아니라 "그래서 Gatekeeper 검증 대신 sha256으로 무결성을 확인합니다"가 된다.

브라우저로 zip을 직접 받는 경로도 여전히 동작하므로 `xattr` 안내는 **버리지 않고** 접어둔다.
macOS 15부터 Control-클릭 → 열기 우회가 제거돼, 그 경로를 택한 사용자에게는 이 명령이
여전히 유일한 출구다.

### 6.2 공증 확장 지점 — 여전히 코드가 아니라 지도

선행 설계문 §6.3의 결정을 유지한다. `make-app.sh`에 `--sign` 인자를 지금 만들지 않는다.

이 리포는 `ci.yml` 주석에서 "태그를 밀기 전까지 한 번도 실행되지 않는 스크립트"를 명시적으로
불신한다. 인증서 없이 넣는 서명 분기는 정확히 그런 코드가 된다 — 실제로 쓰이는 날 어차피
처음 돌아보게 된다.

대신 **구조로 열어둔다.** 이 설계에서 공증 도입 시 코드가 바뀌는 곳은 두 군데뿐이다.

1. `make-app.sh`의 `codesign` 한 줄 — identity · hardened runtime · 타임스탬프,
   그 뒤에 `notarytool submit --wait`와 `stapler staple`
2. cask의 `postflight` 블록 **삭제**

`install.sh`는 손대지 않는다. quarantine을 **제거**하는 로직이 애초에 없고(§3.4), 부재를
확인하는 11번 단계는 공증 이후에도 그대로 유효하다.

채널 구조·검증 구조·문서 구조는 바뀌지 않는다. 남는 것은 §6.1 안내 문구에서 "공증을 받지
않았다"는 문단을 걷어내는 일뿐이다. `make-app.sh`의 기존 확장 지점 주석을 위 두 항목까지
포함하도록 구체화한다.

### 6.3 Keychain 재인증은 남는 마찰이다

파일 기반 Keychain 항목은 코드 서명의 designated requirement에 ACL이 묶인다. ad-hoc 서명의
DR은 `cdhash`라 바이너리가 바뀔 때마다 달라진다. 따라서 **업그레이드마다** 자격증명 접근
프롬프트가 뜬다. Developer ID 서명의 DR은 Team ID 기반이라 버전이 바뀌어도 같다.

`brew upgrade`를 주 경로로 삼은 이상 이 마찰은 정기적으로 드러난다. 이번 범위에서 고치지
않는다 — 공증 도입이 부수적으로 해결하거나, 앱 코드 변경(§8 제외 항목)이 필요하다.
README에 알려진 동작으로 적는다.

---

## 7. 검증 전략

| 층 | 시점 | 무엇을 잡나 |
|---|---|---|
| 1 | 로컬 | `make-cask.sh`를 손으로 돌려 `ruby -c` 통과 확인. `install.sh`는 `sh -n` |
| 2 | `ci.yml` (PR) | 두 스크립트의 인자 처리와 산출물 문법 — 태그 전에 |
| 3 | `release.yml` 10단계 | 실제 `brew install` · `install.sh` 실행 — 사용자 경로 그대로 |
| 4 | 프리릴리즈 리허설 | `v0.1.0-rc.2` 태그로 curl 경로를 실물 검증(§5.5) |

3층이 이 설계의 핵심 안전망이다. 1·2층은 스크립트가 도는지를 보고, 3층은 결과가 옳은지를 본다.

---

## 8. 스코프 경계

### 포함

- `scripts/install.sh` — curl 설치 경로 (§3)
- `scripts/make-cask.sh` — cask 생성 (§4)
- `.github/workflows/release.yml` — 체크섬·cask·tap push·설치 스모크 (§5.1–5.5)
- `.github/workflows/ci.yml` — 새 스크립트 스모크 (§5.3)
- `.github/release-notes-header.md`·`README.md` — 설치 안내 교체 (§6.1)
- `scripts/make-app.sh` — 공증 확장 지점 주석 구체화 (§6.2). **코드 변경 없음**
- `ahngbeom/homebrew-tap`의 `Casks/jirarcade.rb` — 워크플로가 생성

### 제외

- **공증·Developer ID 서명** — 계정이 없다. 구조만 열어둔다 (§6.2)
- **Keychain 저장 방식 변경** — 앱 코드 변경이라 릴리즈 작업의 범위를 넘는다 (§6.3)
- **`homebrew-cask` 본체 등록** — 미서명 앱은 받지 않는다. 자체 tap으로 간다
- **dmg 산출물 · Sparkle 자동 업데이트 · 소스 빌드 formula** — §2.1
- **Linux/Windows** — macOS 전용 앱이다

---

## 9. 완성 정의

1. `brew install --cask ahngbeom/tap/jirarcade`가 앱을 설치하고, **아무 추가 명령 없이**
   더블클릭으로 실행된다
2. `brew upgrade --cask jirarcade`가 새 버전을 가져온다
3. `curl -fsSL … | sh` 한 줄이 같은 결과를 낸다
4. 체크섬이 어긋난 zip에 대해 `install.sh`가 설치하지 않고 중단한다
5. 태그를 밀면 tap의 `Casks/jirarcade.rb` 버전·sha256이 릴리즈 자산과 일치한다
6. 릴리즈 워크플로의 설치 스모크가 두 경로 모두에서 quarantine 부재를 확인한다
7. 프리릴리즈 태그는 tap을 갱신하지 않는다
8. README·릴리즈 노트의 설치 안내가 위 두 줄이고, Keychain 마찰이 알려진 동작으로 적혀 있다

---

## 10. 리스크

| | 리스크 | 대응 |
|---|---|---|
| 1 | **GitHub API 레이트 리밋.** 미인증 요청은 IP당 시간 60회다. `releases/latest` 조회가 막히면 `install.sh`가 버전을 못 정한다 | `JIRARCADE_VERSION`으로 API를 건너뛸 수 있다. 실패 메시지에 이 경로를 적는다 |
| 2 | **Homebrew가 `postflight`의 `xattr` 조작을 막을 수 있다.** `--no-quarantine` 제거가 그 방향을 시사한다 | 막히면 미서명 cask 경로 자체가 닫힌다. 그때는 curl 경로가 폴백이 되고, 공증이 사실상 강제된다 |
| 3 | **`brew audit`를 돌리지 않는다.** `ruby -c`는 문법만 본다 — 유효한 Ruby이지만 잘못된 cask가 통과할 수 있다 | §5.4의 실제 `brew install` 스모크가 이 층을 메운다 |
| 4 | **tap push 충돌.** 릴리즈가 겹치거나 사람이 동시에 tap을 만지면 non-fast-forward로 실패한다 | 별도 job이라 재실행으로 회복된다(§5.2). push 전에 rebase한다 |
| 5 | **`curl \| sh`에 대한 거부감.** 개발자 대상이라도 신뢰하지 않는 사용자가 있다 | sha256 검증(§3.3)과 `sudo` 미사용(§3.5)을 README에 명시한다. 내려받아 읽고 실행하는 경로도 함께 안내한다 |
| 6 | **Keychain 재인증 프롬프트.** 업그레이드마다 뜬다(§6.3) | 이번 범위에서 고치지 않는다. 알려진 동작으로 문서화하고, 공증 도입 시 해소된다 |
| 7 | **첫 시크릿 도입.** PAT 만료나 권한 오설정이 tap 갱신을 막는다 | job이 명시적으로 실패한다(§5.6). 만료일을 릴리즈 노트가 아니라 달력에 둔다 |

---

## 11. 결정 기록

- **선행 설계문의 "Homebrew cask 제외"를 뒤집는다.** 근거였던 "수령자가 소수다"가
  개발자 대상 공개 배포로 바뀌면서 무효가 됐다
- **sha256은 한 번 계산해 둘에 주입한다.** 채널마다 따로 계산하면 어긋나도 아무도 모른다
- **cask 생성은 공개 전, tap push는 공개 후.** 되돌릴 수 있는 실패를 앞으로 당기고,
  되돌릴 수 없는 지점 뒤의 실패에는 재실행 경로를 준다
- **tap 갱신은 별도 job.** 회복 가능성이 설계의 일부다
- **`postflight`는 `appdir`을 쓴다.** `app` stanza는 번들을 옮긴 뒤 postflight를 돌린다
- **quarantine 부재를 명시적으로 검사한다.** `xattr`의 조용한 실패는 사용자의 첫 더블클릭에서만 드러난다
- **`install.sh`는 `sudo`를 부르지 않는다.** `curl \| sh`에서 조용한 권한 상승은 특히 나쁘다
- **공증 코드는 여전히 넣지 않는다.** 선행 설계문 §6.3의 판단을 유지한다 —
  한 번도 돌지 않은 코드를 미리 두지 않고, 구조로만 열어둔다
- **프리릴리즈는 tap을 갱신하지 않는다.** '최신 릴리즈' 자리를 비켜두는 기존 결정과 같은 계열
