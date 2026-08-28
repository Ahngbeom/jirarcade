# Jirarcade 설치 경험 개편 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 받는 사람이 압축을 풀고 앱을 옮기고 `xattr`를 치는 세 단계를, `brew` 한 줄 또는 `curl` 한 줄로 줄인다.

**Architecture:** 릴리즈 zip 하나와 sha256 하나를 두 채널(Homebrew cask · curl 스크립트)이 공유한다. cask 생성은 릴리즈 공개 전에 두어 실패를 앞당기고, tap push와 설치 스모크는 공개 후 별도 job에 두어 재실행으로 회복 가능하게 한다. 공증은 범위 밖이며, 미서명 앱의 격리 딱지는 cask의 `postflight`와 curl의 성질로 각각 해결한다.

**Tech Stack:** bash (POSIX 지향, `#!/bin/bash`) · GitHub Actions (macos-26) · Homebrew cask DSL (Ruby) · 외부 의존성 0개 (`jq` 포함 사용 금지)

**Spec:** `docs/superpowers/specs/2026-08-26-release-install-design.md`

---

## 설계문 정정

계획 작성 중 설계문의 두 지점을 정정한다. 구현은 아래 정정본을 따른다.

**정정 1 — §3.1의 설치 명령을 `| sh`에서 `| bash`로 바꾼다.**
`install.sh`는 함수 단위로 테스트되어야 하고(정정 2), 그러려면 "소스될 때는 `main`을 돌리지 않는" 가드가 필요하다. POSIX `sh`에는 이를 판별할 표준 수단이 없고 `BASH_SOURCE`가 필요하다. 리포의 다른 스크립트도 모두 `#!/bin/bash`다.

**정정 2 — §7 2층에서 `install.sh`를 `sh -n` 문법 검사만 한다는 계획을 폐기한다.**
설계문은 "전체 실행은 실제 릴리즈가 있어야 가능하다"고 적었으나, 이는 이 리포가 명시적으로 불신하는 상태(태그를 밀기 전까지 한 번도 돌지 않는 스크립트)를 그대로 만든다. 함수가 경로를 **인자로** 받게 하면 테스트가 임시 디렉터리를 넘겨 설치·교체·롤백을 전부 검증할 수 있다. 테스트 전용 환경 변수는 만들지 않는다 — 사용자에게 보이는 인터페이스는 §3.1 그대로다.

다른 절은 설계문대로다.

---

## Global Constraints

모든 태스크의 요구사항에 아래가 암묵적으로 포함된다.

- **macOS 최소 버전은 15**다. 세 곳이 같은 값을 말해야 한다: `make-app.sh`의 `LSMinimumSystemVersion` `15.0`, cask의 `depends_on macos: ">= :sequoia"`, `install.sh`의 `MIN_MACOS_MAJOR=15`.
- **저장소는 `Ahngbeom/jirarcade`**, **tap은 `ahngbeom/homebrew-tap`**, **cask 토큰은 `jirarcade`**, **번들 ID는 `dev.jirarcade.app`**.
- **릴리즈 자산명**: `Jirarcade-<version>.zip`, `Jirarcade-<version>.zip.sha256`.
- **외부 의존성을 늘리지 않는다.** `jq`·`actionlint`·`shellcheck`·`bats`를 쓰지 않는다. 사용 가능한 것은 macOS 기본 도구와 러너에 이미 있는 `ruby`·`brew`뿐이다.
- **모든 스크립트는 `set -euo pipefail`로 시작**하고, 헤더 주석에 용도·사용법·왜 이렇게 했는지를 한국어로 적는다. `make-app.sh`·`verify-bundle.sh`의 서식을 따른다.
- **값이 필요한 옵션에 다른 옵션이 오면 거부한다.** `make-app.sh`의 `reject_flag_as_value` 패턴을 그대로 쓴다. 알 수 없는 옵션은 조용히 무시하지 않고 `exit 2`다.
- **커밋 메시지는 한국어 Conventional Commits**다. 기존 이력(`feat: 궤도가 티켓을 읽고 판단하는 화면이 된다`)의 어조를 따른다.

---

## 파일 구조

| 파일 | 책임 |
|---|---|
| `scripts/install.sh` **(신규)** | curl 설치 경로. 버전 결정 · 다운로드 · 체크섬 검증 · 전개 · 교체 |
| `scripts/make-cask.sh` **(신규)** | 버전·sha256을 받아 cask 파일 텍스트를 만든다. 오직 그것만 한다 |
| `scripts/verify-install.sh` **(신규)** | *설치된* 앱이 쓸 수 있는 상태인지 검사. 두 채널이 공유하는 단일 판정 |
| `scripts/test-install.sh` **(신규)** | `install.sh`의 함수 단위 테스트 |
| `scripts/test-make-cask.sh` **(신규)** | `make-cask.sh`의 산출물 테스트 |
| `.github/workflows/release.yml` **(수정)** | 체크섬·cask 생성(공개 전) + tap push·설치 스모크(별도 job) |
| `.github/workflows/ci.yml` **(수정)** | 새 스크립트 스모크 |
| `README.md` · `.github/release-notes-header.md` **(수정)** | 설치 안내 교체 |
| `scripts/make-app.sh` **(주석만)** | 공증 확장 지점 구체화 |

`verify-bundle.sh`는 *빌드된* 번들(아키텍처·버전·아이콘·압축 왕복)을, `verify-install.sh`는 *설치된* 앱(존재·서명·격리 부재)을 본다. 관심사가 달라 나눈다.

---

### Task 1: `make-cask.sh` — cask 생성기

**Files:**
- Create: `scripts/make-cask.sh`
- Create: `scripts/test-make-cask.sh`

**Interfaces:**
- Consumes: 없음
- Produces: `./scripts/make-cask.sh --version <x.y.z> --sha256 <64자리 소문자 16진수> [--output <경로>]`
  - `--output` 없으면 cask 텍스트를 표준 출력으로 낸다
  - 잘못된 버전 형식·해시 형식·알 수 없는 옵션은 `exit 2`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`scripts/test-make-cask.sh`를 만든다. 판정 헬퍼는 `verify-bundle.sh`의 `pass`/`fail` 서식을 따른다.

```bash
#!/bin/bash
# make-cask.sh의 산출물을 검사한다.
#
# cask는 릴리즈 태그를 밀어야만 처음 만들어지는 파일이라, 오타 하나가 공개된
# 태그 위에서만 드러난다. 그 전에 여기서 죽인다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAKE_CASK="$SCRIPT_DIR/make-cask.sh"
SHA="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

FAILED=0
fail() { echo "✗ $1" >&2; FAILED=1; }
pass() { echo "✓ $1"; }

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label — '$needle'이(가) 없습니다"
    fi
}

assert_rejects() {
    local label="$1"; shift
    if "$MAKE_CASK" "$@" >/dev/null 2>&1; then
        fail "$label — 거부해야 하는데 성공했습니다"
    else
        pass "$label"
    fi
}

CASK="$("$MAKE_CASK" --version 0.2.0 --sha256 "$SHA")"

# 1. 주입값이 실제로 들어갔나. 버전이 조용히 0.0.0으로 나가는 것을 막는다.
assert_contains "버전 주입" "$CASK" 'version "0.2.0"'
assert_contains "sha256 주입" "$CASK" "sha256 \"$SHA\""

# 2. 미서명 앱이 실행되려면 postflight의 xattr가 반드시 있어야 한다.
#    Homebrew 6.x에서 --no-quarantine이 제거돼 이것이 유일한 경로다.
assert_contains "격리 해제 postflight" "$CASK" "com.apple.quarantine"
assert_contains "postflight 대상은 appdir" "$CASK" '#{appdir}/Jirarcade.app'

# 3. macOS 하한이 Info.plist의 LSMinimumSystemVersion과 같은 값을 말해야 한다.
assert_contains "macOS 하한" "$CASK" 'depends_on macos: ">= :sequoia"'

# 4. zap 대상은 앱이 실제로 쓰는 경로다.
assert_contains "zap — Application Support" "$CASK" "~/Library/Application Support/Jirarcade"
assert_contains "zap — 환경설정 plist" "$CASK" "~/Library/Preferences/dev.jirarcade.app.plist"

# 5. Keychain은 zap이 못 지운다. 조용히 남기지 않고 알린다.
assert_contains "Keychain caveats" "$CASK" "Keychain"

# 6. url이 릴리즈 자산명과 어긋나면 brew가 404를 받는다.
assert_contains "다운로드 URL" "$CASK" \
    'https://github.com/Ahngbeom/jirarcade/releases/download/v#{version}/Jirarcade-#{version}.zip'

# 7. 유효한 Ruby인가. cask DSL 오류까지는 못 잡지만 문법 오류는 여기서 죽는다.
RUBY_TMP="$(mktemp -d)"
trap 'rm -rf "$RUBY_TMP"' EXIT
printf '%s\n' "$CASK" > "$RUBY_TMP/jirarcade.rb"
if ruby -c "$RUBY_TMP/jirarcade.rb" >/dev/null 2>&1; then
    pass "Ruby 문법 유효"
else
    fail "Ruby 문법 오류"
    ruby -c "$RUBY_TMP/jirarcade.rb" >&2 || true
fi

# 8. --output이 파일로 나가는가.
"$MAKE_CASK" --version 1.2.3 --sha256 "$SHA" --output "$RUBY_TMP/out.rb"
if [[ -s "$RUBY_TMP/out.rb" ]] && grep -q 'version "1.2.3"' "$RUBY_TMP/out.rb"; then
    pass "--output 파일 출력"
else
    fail "--output이 파일을 만들지 못했습니다"
fi

# 9. 잘못된 입력을 거부하는가. 조용히 통과하면 CI 오타가 그대로 tap에 박힌다.
assert_rejects "버전 누락 거부" --sha256 "$SHA"
assert_rejects "해시 누락 거부" --version 0.2.0
assert_rejects "잘못된 버전 형식 거부" --version 0.2 --sha256 "$SHA"
assert_rejects "짧은 해시 거부" --version 0.2.0 --sha256 "abc123"
# macOS의 /bin/bash는 3.2다. ${SHA^^}는 bash 4.0+ 문법이라 파싱 단계에서 죽는다.
assert_rejects "대문자 해시 거부" --version 0.2.0 --sha256 "$(printf '%s' "$SHA" | tr 'a-f' 'A-F')"
assert_rejects "알 수 없는 옵션 거부" --version 0.2.0 --sha256 "$SHA" --univeral
assert_rejects "값 자리에 온 옵션 거부" --version --sha256 "$SHA"

if [[ $FAILED -eq 1 ]]; then
    echo "" >&2
    echo "✗ make-cask.sh 테스트 실패" >&2
    exit 1
fi
echo "✓ make-cask.sh 테스트 통과"
```

- [ ] **Step 2: 테스트를 돌려 실패를 확인한다**

```bash
chmod +x scripts/test-make-cask.sh
./scripts/test-make-cask.sh
```

Expected: FAIL — `make-cask.sh`가 없어 `"$MAKE_CASK" ...` 호출이 "No such file or directory"로 죽는다.

- [ ] **Step 3: `make-cask.sh`를 구현한다**

```bash
#!/bin/bash
# 릴리즈 zip의 버전과 sha256을 받아 Homebrew cask 파일을 만든다.
#
# 워크플로 YAML이 아니라 스크립트로 둔 이유는 verify-bundle.sh와 같다 — 로컬과
# CI가 같은 코드를 돌아야 한다. cask 본문을 YAML 히어독에 넣으면 그 동일성은
# 첫 수정에서 깨진다.
#
# 이 스크립트는 파일을 만들기만 한다. 체크섬 계산도, tap push도 하지 않는다.
# sha256은 릴리즈 워크플로가 zip에서 한 번 계산해 이 스크립트와 릴리즈 자산
# 양쪽에 넘긴다 — 두 곳이 따로 계산하면 어긋나도 아무도 모른다.
#
# 사용법: ./scripts/make-cask.sh --version 0.2.0 --sha256 <64자리>
#         ./scripts/make-cask.sh --version 0.2.0 --sha256 <64자리> --output Casks/jirarcade.rb
#
# 옵션:
#   --version <x.y.z>   cask의 version           (필수)
#   --sha256 <해시>     zip의 sha256, 64자리 소문자 16진수 (필수)
#   --output <경로>     쓸 파일                  (기본: 표준 출력)
set -euo pipefail

VERSION=""
SHA256=""
OUTPUT=""

# 값이 필요한 옵션에 다른 옵션이 그대로 들어오면 조용히 잘못된 값이 박힌다.
# make-app.sh와 같은 방어다.
reject_flag_as_value() {
    local flag="$1" value="${2-}"
    case "$value" in
        --*) echo "✗ ${flag}에 값 대신 옵션이 왔습니다: $value" >&2; exit 2 ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) reject_flag_as_value --version "${2:-}"; VERSION="${2:?--version 값이 필요합니다}"; shift 2 ;;
        --sha256)  reject_flag_as_value --sha256 "${2:-}";  SHA256="${2:?--sha256 값이 필요합니다}";  shift 2 ;;
        --output)  reject_flag_as_value --output "${2:-}";  OUTPUT="${2:?--output 값이 필요합니다}";  shift 2 ;;
        # 조용히 무시하면 CI의 오타가 그대로 tap에 박힌다.
        *) echo "✗ 알 수 없는 옵션: $1" >&2; exit 2 ;;
    esac
done

# 릴리즈 워크플로의 태그 검증과 같은 형식이다. v0.2 같은 값이 cask의 version에
# 들어가면 url이 존재하지 않는 자산을 가리킨다.
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "✗ --version 형식이 올바르지 않습니다: '$VERSION' (예: 0.2.0, 0.2.0-rc.1)" >&2
    exit 2
fi

# shasum 출력은 소문자다. 대문자나 잘린 값이 들어오면 brew가 다운로드 후에야
# 실패하는데, 그때는 이미 릴리즈가 공개된 뒤다.
if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "✗ --sha256은 64자리 소문자 16진수여야 합니다: '$SHA256'" >&2
    exit 2
fi

# 히어독에 따옴표가 없어 ${VERSION}·${SHA256}이 확장된다. 본문의 #{version}과
# #{appdir}은 Ruby 보간이라 셸이 건드리지 않는다 — $나 백틱이 없기 때문이다.
# make-app.sh의 Info.plist 히어독과 같은 이유로 같은 방식을 쓴다.
CASK=$(cat <<CASKRB
cask "jirarcade" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/Ahngbeom/jirarcade/releases/download/v#{version}/Jirarcade-#{version}.zip",
      verified: "github.com/Ahngbeom/jirarcade/"

  name "Jirarcade"
  desc "macOS app that shows Jira tickets as an arcade game"
  homepage "https://github.com/Ahngbeom/jirarcade"

  # Info.plist의 LSMinimumSystemVersion 15.0과 같은 값이어야 한다. 어긋나면
  # cask는 설치를 허용하는데 앱이 켜지지 않는다.
  depends_on macos: ">= :sequoia"

  livecheck do
    skip "Auto-generated on release."
  end

  app "Jirarcade.app"

  # 이 앱은 공증을 받지 않았다. Homebrew는 내려받은 자산에 격리 표시를 붙이고,
  # 6.x에서 --no-quarantine 플래그가 제거돼 사용자가 뗄 방법이 없다. 여기서 뗀다.
  #
  # staged_path가 아니라 appdir인 이유: app stanza는 번들을 /Applications로 옮긴
  # 뒤에 postflight를 돌린다. staged_path는 그 시점에 비어 있어 아무 효과 없이 성공한다.
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
CASKRB
)

if [[ -n "$OUTPUT" ]]; then
    printf '%s\n' "$CASK" > "$OUTPUT"
else
    printf '%s\n' "$CASK"
fi
```

- [ ] **Step 4: 테스트를 돌려 통과를 확인한다**

```bash
chmod +x scripts/make-cask.sh
./scripts/test-make-cask.sh
```

Expected: 모든 항목 `✓`, 마지막 줄 `✓ make-cask.sh 테스트 통과`.

- [ ] **Step 5: 커밋한다**

```bash
git add scripts/make-cask.sh scripts/test-make-cask.sh
git commit -m "feat: 릴리즈가 cask 파일을 스스로 만든다"
```

---

### Task 2: `install.sh` — 판정 함수들

**Files:**
- Create: `scripts/install.sh` (함수 정의 + `BASH_SOURCE` 가드만. `main`은 Task 3)
- Create: `scripts/test-install.sh`

**Interfaces:**
- Consumes: 없음
- Produces: `install.sh`를 `source`하면 아래 함수가 노출된다. `main`은 이 태스크에서 만들지 않는다.
  - `macos_version_ok <버전문자열>` → 주 버전이 `MIN_MACOS_MAJOR`(15) 이상이면 0
  - `parse_tag_name` → 표준 입력의 GitHub 릴리즈 JSON에서 `tag_name` 값을 표준 출력으로. 없으면 빈 출력
  - `verify_checksum <파일> <shasum파일>` → 일치하면 0, 아니면 1과 표준 오류 메시지

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`scripts/test-install.sh`:

```bash
#!/bin/bash
# install.sh의 함수를 직접 불러 검사한다.
#
# 이 스크립트를 source하면 main이 돌지 않는다(BASH_SOURCE 가드). 덕분에 실제
# 릴리즈나 네트워크 없이 판정 로직 전체를 검증할 수 있다. 설치 대상 디렉터리도
# 인자로 받으므로 /Applications를 건드리지 않는다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

FAILED=0
fail() { echo "✗ $1" >&2; FAILED=1; }
pass() { echo "✓ $1"; }

assert_eq() {
    local label="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$label"
    else
        fail "$label — 기대 '$expected', 실제 '$actual'"
    fi
}

assert_ok() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label — 성공해야 합니다"; fi
}

assert_fails() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then fail "$label — 실패해야 합니다"; else pass "$label"; fi
}

# main이 돌면 여기서 /Applications에 설치를 시도한다. 돌지 않아야 한다.
# shellcheck source=./install.sh
source "$SCRIPT_DIR/install.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- macos_version_ok ---
# Info.plist의 LSMinimumSystemVersion 15.0과 같은 경계여야 한다.
assert_ok    "macOS 15.0 허용"   macos_version_ok "15.0"
assert_ok    "macOS 15.4.1 허용" macos_version_ok "15.4.1"
assert_ok    "macOS 26.2 허용"   macos_version_ok "26.2"
assert_fails "macOS 14.7 거부"   macos_version_ok "14.7"
assert_fails "빈 값 거부"        macos_version_ok ""
assert_fails "숫자 아닌 값 거부" macos_version_ok "sequoia"

# --- parse_tag_name ---
# jq를 쓰지 않는다. 사용자 기계에 있다고 보장할 수 없다.
assert_eq "tag_name 추출" \
    "$(printf '{"url":"x","tag_name":"v0.2.0","name":"Jirarcade 0.2.0"}' | parse_tag_name)" \
    "v0.2.0"
assert_eq "공백이 있어도 추출" \
    "$(printf '{ "tag_name" : "v1.0.0-rc.1" }' | parse_tag_name)" \
    "v1.0.0-rc.1"
assert_eq "tag_name이 없으면 빈 출력" \
    "$(printf '{"message":"Not Found"}' | parse_tag_name)" \
    ""

# --- verify_checksum ---
printf 'jirarcade' > "$TMP/payload"
GOOD="$(shasum -a 256 "$TMP/payload" | awk '{print $1}')"

# 릴리즈 자산은 shasum 원본 형식(<해시><공백2><파일명>)이다.
printf '%s  Jirarcade-0.2.0.zip\n' "$GOOD" > "$TMP/good.sha256"
assert_ok "일치하는 체크섬 통과" verify_checksum "$TMP/payload" "$TMP/good.sha256"

# 파일명이 달라도 통과해야 한다 — 임시 파일명은 자산명과 다르다.
# 이것이 `shasum -c`를 쓰지 않는 이유다.
printf '%s  전혀-다른-이름.zip\n' "$GOOD" > "$TMP/renamed.sha256"
assert_ok "파일명이 달라도 통과" verify_checksum "$TMP/payload" "$TMP/renamed.sha256"

printf '%064d  Jirarcade-0.2.0.zip\n' 0 > "$TMP/bad.sha256"
assert_fails "불일치 체크섬 거부" verify_checksum "$TMP/payload" "$TMP/bad.sha256"

printf 'not-a-hash  Jirarcade-0.2.0.zip\n' > "$TMP/malformed.sha256"
assert_fails "형식이 깨진 체크섬 파일 거부" verify_checksum "$TMP/payload" "$TMP/malformed.sha256"

printf '' > "$TMP/empty.sha256"
assert_fails "빈 체크섬 파일 거부" verify_checksum "$TMP/payload" "$TMP/empty.sha256"

if [[ $FAILED -eq 1 ]]; then
    echo "" >&2
    echo "✗ install.sh 테스트 실패" >&2
    exit 1
fi
echo "✓ install.sh 테스트 통과"
```

- [ ] **Step 2: 테스트를 돌려 실패를 확인한다**

```bash
chmod +x scripts/test-install.sh
./scripts/test-install.sh
```

Expected: FAIL — `source: scripts/install.sh: No such file or directory`.

- [ ] **Step 3: `install.sh`의 함수부를 구현한다**

```bash
#!/bin/bash
# Jirarcade를 GitHub 릴리즈에서 받아 /Applications에 설치한다.
#
# curl로 받는 것이 이 스크립트의 핵심이다. com.apple.quarantine 확장 속성은
# 파일을 내려받은 프로세스가 붙인다 — LSFileQuarantineEnabled를 선언한
# 앱(브라우저·메일·AirDrop)만 해당된다. curl은 선언하지 않으므로 격리 표시가
# 애초에 생기지 않는다. 브라우저로 받았을 때 필요한 `xattr -d`가 여기서는
# 뗄 딱지가 없어서 필요 없다. Gatekeeper 우회가 아니라 다른 경로다.
#
# 그 대가로 Gatekeeper의 보증도 받지 못한다. 그 자리를 sha256이 메운다 —
# 릴리즈에 함께 올라온 .sha256과 대조하고, 어긋나면 설치하지 않는다. 이 검증이
# 없으면 이 스크립트는 "아무거나 받아서 실행"과 구별되지 않는다.
#
# 사용법:
#   curl -fsSL https://raw.githubusercontent.com/Ahngbeom/jirarcade/main/scripts/install.sh | bash
#   JIRARCADE_VERSION=0.2.0 로 특정 버전 고정 (프리릴리즈 설치의 유일한 경로)
#
# sudo를 부르지 않는다. /Applications에 쓸 수 없으면 그 사실을 알리고 멈춘다 —
# curl | bash로 실행되는 스크립트가 조용히 권한을 올리는 것은 특히 나쁘다.
set -euo pipefail

REPO="Ahngbeom/jirarcade"
APP_NAME="Jirarcade.app"
INSTALL_DIR="/Applications"

# Info.plist의 LSMinimumSystemVersion 15.0과 같은 값이어야 한다.
MIN_MACOS_MAJOR=15

# 정리 대상. main이 설정하고 trap이 읽는다. main의 지역 변수로 두면 trap이
# 실행되는 시점에는 이미 사라지고 없다.
WORKDIR=""

cleanup() {
    [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
    return 0
}

# sw_vers -productVersion의 주 버전만 본다. 부 버전까지 비교하면 15.0 하한에
# 대해 문자열 비교가 15.10 < 15.9 같은 오답을 낸다.
macos_version_ok() {
    local version="${1-}" major
    major="${version%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] || return 1
    (( major >= MIN_MACOS_MAJOR ))
}

# GitHub 릴리즈 JSON에서 tag_name을 꺼낸다. jq에 의존하지 않는다 — 받는 사람의
# 기계에 있다고 보장할 수 없고, 그것 하나 때문에 설치가 막히면 안 된다.
# 응답에서 tag_name은 한 번만 나오므로 첫 일치로 충분하다.
parse_tag_name() {
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# shasum 파일의 첫 필드만 비교한다. `shasum -c`를 쓰지 않는 이유: 그쪽은 기록된
# 파일명까지 일치해야 하는데, 검증 시점의 임시 파일명은 릴리즈 자산명과 다르다.
verify_checksum() {
    local file="$1" sums_file="$2" expected actual
    expected="$(awk 'NR==1 {print $1}' "$sums_file" 2>/dev/null || true)"
    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        echo "✗ 체크섬 파일 형식이 올바르지 않습니다: $sums_file" >&2
        return 1
    fi
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "✗ 체크섬이 일치하지 않습니다 — 설치를 중단합니다" >&2
        echo "  기대: $expected" >&2
        echo "  실제: $actual" >&2
        return 1
    fi
    return 0
}

# 이 파일이 source될 때는 main을 돌리지 않는다 — 테스트가 함수만 꺼내 쓴다.
# curl | bash로 실행되면 BASH_SOURCE[0]이 없으므로 $0으로 대체해 참이 된다.
# ${BASH_SOURCE[0]:-$0}의 :- 가 없으면 set -u 아래에서 unbound variable로 죽는다.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    echo "✗ main이 아직 구현되지 않았습니다" >&2
    exit 1
fi
```

- [ ] **Step 4: 테스트를 돌려 통과를 확인한다**

```bash
chmod +x scripts/install.sh
./scripts/test-install.sh
```

Expected: 모든 항목 `✓`, 마지막 줄 `✓ install.sh 테스트 통과`. `main이 아직 구현되지 않았습니다`는 **나오지 않아야** 한다 — 나온다면 `BASH_SOURCE` 가드가 틀린 것이다.

- [ ] **Step 5: 커밋한다**

```bash
git add scripts/install.sh scripts/test-install.sh
git commit -m "feat: 설치 스크립트가 버전과 무결성을 스스로 판정한다"
```

---

### Task 3: `install.sh` — 설치·교체·롤백과 `main`

**Files:**
- Modify: `scripts/install.sh` (`install_bundle`와 `main` 추가, Task 2의 자리표시자 가드 교체)
- Modify: `scripts/test-install.sh` (`install_bundle` 테스트 추가)

**Interfaces:**
- Consumes: Task 2의 `macos_version_ok`, `parse_tag_name`, `verify_checksum`, `cleanup`, 전역 `APP_NAME`·`INSTALL_DIR`·`WORKDIR`·`REPO`·`MIN_MACOS_MAJOR`
- Produces:
  - `install_bundle <staged_app_경로> <대상_디렉터리>` → 성공 0. 기존 앱이 있으면 옆으로 치웠다가, 실패하면 되돌린다
  - `main` — `curl … | bash` 진입점. 인자를 받지 않고 `JIRARCADE_VERSION` 환경 변수만 읽는다

- [ ] **Step 1: 실패하는 테스트를 추가한다**

`scripts/test-install.sh`의 `verify_checksum` 블록 **뒤**, 최종 판정(`if [[ $FAILED -eq 1 ]]`) **앞**에 넣는다.

```bash
# --- install_bundle ---
# 기존 앱이 없을 때
mkdir -p "$TMP/dest1" "$TMP/staged1/Jirarcade.app/Contents"
printf 'new' > "$TMP/staged1/Jirarcade.app/Contents/marker"
assert_ok "새 설치" install_bundle "$TMP/staged1/Jirarcade.app" "$TMP/dest1"
assert_eq "새 설치 내용" \
    "$(cat "$TMP/dest1/Jirarcade.app/Contents/marker" 2>/dev/null || echo MISSING)" "new"

# 기존 앱이 있을 때 — brew upgrade와 재설치가 밟는 경로다
mkdir -p "$TMP/dest2/Jirarcade.app/Contents" "$TMP/staged2/Jirarcade.app/Contents"
printf 'old' > "$TMP/dest2/Jirarcade.app/Contents/marker"
printf 'new' > "$TMP/staged2/Jirarcade.app/Contents/marker"
assert_ok "기존 앱 교체" install_bundle "$TMP/staged2/Jirarcade.app" "$TMP/dest2"
assert_eq "교체 후 내용" "$(cat "$TMP/dest2/Jirarcade.app/Contents/marker")" "new"

# 롤백 — 이 설계의 핵심 안전 성질이다. 새 번들을 넣지 못하면 기존 앱이 남아야 한다.
#
# mv는 원본의 **부모 디렉터리**에 쓰기 권한이 있어야 항목을 지울 수 있다. 부모를
# 읽기 전용으로 만들면 기존 앱을 치우는 첫 mv는 성공하고 새것을 넣는 두 번째 mv만
# 실패한다 — 정확히 롤백 경로를 밟게 하는 조건이다.
mkdir -p "$TMP/dest3/Jirarcade.app/Contents" "$TMP/ro/Jirarcade.app/Contents"
printf 'old' > "$TMP/dest3/Jirarcade.app/Contents/marker"
printf 'new' > "$TMP/ro/Jirarcade.app/Contents/marker"
chmod 500 "$TMP/ro"
assert_fails "옮기지 못하면 실패" install_bundle "$TMP/ro/Jirarcade.app" "$TMP/dest3"
assert_eq "실패 후 기존 앱 보존" \
    "$(cat "$TMP/dest3/Jirarcade.app/Contents/marker" 2>/dev/null || echo MISSING)" "old"
chmod 700 "$TMP/ro"

# 잘못된 인자
mkdir -p "$TMP/staged4/Jirarcade.app"
assert_fails "없는 번들 거부"      install_bundle "$TMP/nonexistent/Jirarcade.app" "$TMP/dest1"
assert_fails "없는 설치 위치 거부" install_bundle "$TMP/staged4/Jirarcade.app" "$TMP/nowhere"
```

- [ ] **Step 2: 테스트를 돌려 실패를 확인한다**

```bash
./scripts/test-install.sh
```

Expected: FAIL — `install_bundle: command not found`. Task 2의 함수 테스트는 계속 `✓`여야 한다.

- [ ] **Step 3: `install_bundle`과 `main`을 구현한다**

`verify_checksum` 뒤, `BASH_SOURCE` 가드 앞에 넣는다.

```bash
# 검증을 통과한 번들만 여기 온다. 기존 앱을 옆으로 치우고 새것을 넣은 뒤, 실패하면
# 되돌린다. 디렉터리 교체라 진짜 원자적일 수는 없다 — 창을 좁히는 것이 할 수 있는
# 전부이고, 그 창을 0으로 만드는 것은 이 규모에서 과하다.
install_bundle() {
    local staged="$1" dest_dir="$2"
    local dest="${dest_dir}/${APP_NAME}"
    local backup_dir=""

    if [[ ! -d "$staged" ]]; then
        echo "✗ 설치할 번들이 없습니다: $staged" >&2
        return 1
    fi
    if [[ ! -d "$dest_dir" ]]; then
        echo "✗ 설치 위치가 없습니다: $dest_dir" >&2
        return 1
    fi

    if [[ -e "$dest" ]]; then
        backup_dir="$(mktemp -d)"
        if ! mv "$dest" "$backup_dir/"; then
            echo "✗ 기존 앱을 옮기지 못했습니다: $dest" >&2
            rm -rf "$backup_dir"
            return 1
        fi
    fi

    if ! mv "$staged" "$dest"; then
        echo "✗ 새 번들을 설치하지 못했습니다: $dest" >&2
        if [[ -n "$backup_dir" ]]; then
            if mv "$backup_dir/${APP_NAME}" "$dest"; then
                echo "▸ 기존 앱을 되돌렸습니다" >&2
            else
                echo "✗ 되돌리기도 실패했습니다. 기존 앱은 여기 있습니다: ${backup_dir}/${APP_NAME}" >&2
                return 1
            fi
            rm -rf "$backup_dir"
        fi
        return 1
    fi

    [[ -n "$backup_dir" ]] && rm -rf "$backup_dir"
    return 0
}

main() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "✗ macOS 전용입니다" >&2
        exit 1
    fi

    local os_version
    os_version="$(sw_vers -productVersion)"
    if ! macos_version_ok "$os_version"; then
        echo "✗ macOS ${MIN_MACOS_MAJOR} 이상이 필요합니다 (현재: ${os_version})" >&2
        exit 1
    fi

    # 실행 중인 앱을 덮어쓰면 그 프로세스가 사라진 파일을 붙들고 이상하게 동작한다.
    #
    # `pgrep … && { …; exit 1; }` 형태로 쓰지 않는다 — pgrep이 아무것도 못 찾으면
    # 그 목록 전체가 실패로 평가돼 set -e가 스크립트를 죽인다. 앱이 안 켜져 있는
    # 정상 경로에서 죽는 것이다.
    if pgrep -x JirarcadeApp >/dev/null 2>&1; then
        echo "✗ Jirarcade가 실행 중입니다. 종료한 뒤 다시 실행하세요" >&2
        exit 1
    fi

    if [[ ! -w "$INSTALL_DIR" ]]; then
        echo "✗ ${INSTALL_DIR}에 쓸 권한이 없습니다" >&2
        echo "  이 스크립트는 sudo를 부르지 않습니다. 권한을 확인한 뒤 다시 실행하세요." >&2
        exit 1
    fi

    local version="${JIRARCADE_VERSION:-}"
    if [[ -z "$version" ]]; then
        local tag
        # releases/latest는 초안과 프리릴리즈를 제외한다. 프리릴리즈를 받으려면
        # JIRARCADE_VERSION으로 직접 지정해야 한다.
        tag="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | parse_tag_name || true)"
        if [[ -z "$tag" ]]; then
            echo "✗ 최신 버전을 확인하지 못했습니다 (요청 실패 또는 API 레이트 리밋)" >&2
            echo "  미인증 요청은 IP당 시간 60회로 제한됩니다. 버전을 직접 지정하면 이 요청을 건너뜁니다:" >&2
            echo "    JIRARCADE_VERSION=0.2.0 로 시작하는 형태로 다시 실행하세요" >&2
            exit 1
        fi
        version="${tag#v}"
    fi

    local base="https://github.com/${REPO}/releases/download/v${version}"
    WORKDIR="$(mktemp -d)"
    trap cleanup EXIT

    echo "▸ Jirarcade ${version} 내려받는 중…"
    curl -fL --progress-bar -o "${WORKDIR}/app.zip" "${base}/Jirarcade-${version}.zip"
    curl -fsSL -o "${WORKDIR}/app.zip.sha256" "${base}/Jirarcade-${version}.zip.sha256"

    echo "▸ 체크섬 확인 중…"
    verify_checksum "${WORKDIR}/app.zip" "${WORKDIR}/app.zip.sha256"

    # unzip이 아니라 ditto다. unzip은 확장 속성을 잃어 압축을 푼 .app의 서명이 깨진다.
    # 릴리즈 워크플로도 같은 이유로 ditto로 압축한다 — 양쪽이 짝을 이룬다.
    echo "▸ 압축 푸는 중…"
    ditto -x -k "${WORKDIR}/app.zip" "${WORKDIR}/unpacked"

    # 교체보다 검증이 먼저다. 여기서 죽으면 기존 앱이 그대로 남는다.
    echo "▸ 서명 확인 중…"
    codesign --verify --strict "${WORKDIR}/unpacked/${APP_NAME}"

    echo "▸ 설치 중…"
    install_bundle "${WORKDIR}/unpacked/${APP_NAME}" "$INSTALL_DIR"

    # 설치 후 재확인. verify-install.sh를 부르지 않는 이유: 이 스크립트는 curl로
    # 단독 실행돼 옆에 형제 파일이 없다.
    codesign --verify --strict "${INSTALL_DIR}/${APP_NAME}"
    if xattr -p com.apple.quarantine "${INSTALL_DIR}/${APP_NAME}" >/dev/null 2>&1; then
        echo "✗ 격리 표시가 붙어 있습니다 — curl 경로에서는 나올 수 없는 상태입니다" >&2
        echo "  떼는 명령: xattr -dr com.apple.quarantine ${INSTALL_DIR}/${APP_NAME}" >&2
        exit 1
    fi

    echo "✓ ${INSTALL_DIR}/${APP_NAME} (${version})"
    echo "  실행: open ${INSTALL_DIR}/${APP_NAME}"
}
```

그리고 Task 2에서 넣은 자리표시자 가드를 교체한다.

```bash
# 이 파일이 source될 때는 main을 돌리지 않는다 — 테스트가 함수만 꺼내 쓴다.
# curl | bash로 실행되면 BASH_SOURCE[0]이 없으므로 $0으로 대체해 참이 된다.
# ${BASH_SOURCE[0]:-$0}의 :- 가 없으면 set -u 아래에서 unbound variable로 죽는다.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
```

- [ ] **Step 4: 테스트를 돌려 통과를 확인한다**

```bash
./scripts/test-install.sh
bash -n scripts/install.sh
```

Expected: 모든 항목 `✓`, `✓ install.sh 테스트 통과`. 문법 검사는 무출력.

- [ ] **Step 5: 커밋한다**

```bash
git add scripts/install.sh scripts/test-install.sh
git commit -m "feat: 설치 스크립트가 실패하면 기존 앱을 되돌린다"
```

---

### Task 4: `verify-install.sh` — 두 채널이 공유하는 설치 판정

**Files:**
- Create: `scripts/verify-install.sh`
- Modify: `.github/workflows/ci.yml` (`번들 스모크` 스텝 뒤에 새 스텝 추가)

**Interfaces:**
- Consumes: `make-app.sh`가 만든 번들 구조 (`Contents/MacOS/JirarcadeApp`, `Contents/Info.plist`)
- Produces: `./scripts/verify-install.sh <app-경로> [기대-버전]` → 모든 검사 통과 시 0. Task 6의 두 스모크가 이것을 부른다

- [ ] **Step 1: 검증 대상을 만들고, 스크립트가 없어 실패하는 것을 확인한다**

```bash
./scripts/make-app.sh --config release --version 0.0.0-ci --build 0
./scripts/verify-install.sh Packages/Jirarcade/.build/Jirarcade.app 0.0.0-ci
```

Expected: FAIL — `no such file or directory: ./scripts/verify-install.sh`.

- [ ] **Step 2: `verify-install.sh`를 구현한다**

```bash
#!/bin/bash
# 설치된 Jirarcade가 실제로 쓸 수 있는 상태인지 검사한다.
#
# verify-bundle.sh와 관심사가 다르다. 그쪽은 *빌드된* 번들을 본다 —
# 아키텍처·버전·아이콘·압축 왕복. 이쪽은 *설치된* 앱을 본다 — 있는가, 서명이
# 살아있는가, 격리 표시가 없는가, 기대한 버전인가.
#
# 두 설치 채널(brew cask, install.sh)이 같은 판정을 쓰게 하려고 스크립트로 뒀다.
# 워크플로 YAML에 검사를 두 번 적으면 그 동일성은 첫 수정에서 깨진다.
#
# 사용법: ./scripts/verify-install.sh /Applications/Jirarcade.app [0.2.0]
set -euo pipefail

APP="${1:?사용법: verify-install.sh <app-경로> [기대-버전]}"
EXPECTED_VERSION="${2:-}"

FAILED=0
fail() { echo "✗ $1" >&2; FAILED=1; }
pass() { echo "✓ $1"; }

if [[ ! -d "$APP" ]]; then
    echo "✗ 앱이 없습니다: $APP" >&2
    exit 1
fi
pass "설치됨: $APP"

if [[ -x "$APP/Contents/MacOS/JirarcadeApp" ]]; then
    pass "실행 파일 존재"
else
    fail "실행 파일이 없습니다: $APP/Contents/MacOS/JirarcadeApp"
fi

if CODESIGN_ERR="$(codesign --verify --strict "$APP" 2>&1)"; then
    pass "서명 유효"
else
    fail "codesign 검증 실패 — 실행이 차단됩니다"
    echo "$CODESIGN_ERR" >&2
fi

# 격리 표시가 남아 있으면 사용자는 첫 더블클릭에서 "손상되었기 때문에 열 수
# 없습니다"를 만난다. cask의 postflight가 조용히 실패해도 brew install은 성공으로
# 끝나므로, 여기서 보지 않으면 아무도 모른다. "명령이 성공했다"와 "결과가 옳다"는
# 다르다 — verify-bundle.sh가 아이콘의 매직 넘버까지 확인하는 것과 같은 계열이다.
if xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then
    fail "격리 표시가 남아 있습니다 — 첫 실행이 차단됩니다"
else
    pass "격리 표시 없음"
fi

ACTUAL_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null || echo "<없음>")"
if [[ -z "$EXPECTED_VERSION" ]]; then
    pass "버전: $ACTUAL_VERSION (확인 생략)"
elif [[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]]; then
    pass "버전: $ACTUAL_VERSION"
else
    # tap push가 반영되지 않았거나 brew가 옛 cask를 썼다면 여기서만 드러난다.
    # 다른 검사는 이전 버전에 대해서도 전부 통과하기 때문이다.
    fail "버전 불일치 — 기대 '$EXPECTED_VERSION', 실제 '$ACTUAL_VERSION'"
fi

if [[ $FAILED -eq 1 ]]; then
    echo "" >&2
    echo "✗ 설치된 앱을 쓸 수 없습니다." >&2
    exit 1
fi

echo "✓ 설치 확인 완료"
```

- [ ] **Step 3: 로컬에서 통과를 확인한다**

```bash
chmod +x scripts/verify-install.sh
./scripts/verify-install.sh Packages/Jirarcade/.build/Jirarcade.app 0.0.0-ci
```

Expected: 다섯 줄 모두 `✓`, 마지막 `✓ 설치 확인 완료`.

버전 불일치가 실제로 잡히는지도 확인한다.

```bash
./scripts/verify-install.sh Packages/Jirarcade/.build/Jirarcade.app 9.9.9
```

Expected: FAIL — `✗ 버전 불일치 — 기대 '9.9.9', 실제 '0.0.0-ci'`, 종료 코드 1.

- [ ] **Step 4: `ci.yml`에 스모크를 배선한다**

`.github/workflows/ci.yml`의 `번들 스모크` 스텝 **뒤**에 붙인다. 앞 스텝이 이미
`--version 0.0.0-ci`로 번들을 만들어 두므로 그것을 그대로 검사 대상으로 쓴다.

```yaml
      # install.sh·make-cask.sh·verify-install.sh도 v* 태그를 밀기 전까지 한 번도
      # 실행되지 않으면, 버그가 공개된 태그 위에서만 드러난다. 번들 스모크와 같은
      # 이유로 여기서 돌린다.
      #
      # 앞 스텝이 만든 0.0.0-ci 번들을 검사 대상으로 재사용한다. 로컬에서 만든
      # 번들에는 격리 표시가 없으므로 verify-install.sh의 성공 경로가 그대로 성립한다.
      - name: 설치 스크립트 스모크
        working-directory: .
        run: |
          bash -n scripts/install.sh
          ./scripts/test-install.sh
          ./scripts/test-make-cask.sh
          ./scripts/verify-install.sh Packages/Jirarcade/.build/Jirarcade.app 0.0.0-ci
```

- [ ] **Step 5: YAML 문법을 확인하고 커밋한다**

```bash
ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml"); puts "✓ ci.yml 문법 유효"'
git add scripts/verify-install.sh .github/workflows/ci.yml
git commit -m "feat: 두 설치 채널이 같은 판정을 공유한다"
```

---

### Task 5: `release.yml` — 체크섬과 cask를 공개 전에 만든다

**Files:**
- Modify: `.github/workflows/release.yml` (`release` 잡에 `outputs` 추가, `압축` 뒤에 새 스텝, `릴리즈 생성` 수정)

**Interfaces:**
- Consumes: Task 1의 `make-cask.sh`
- Produces: `release` 잡의 출력 세 개 — `version`, `prerelease`, `sha256`. Task 6이 이것을 읽는다

- [ ] **Step 1: 잡 출력을 선언한다**

`jobs.release`의 `runs-on: macos-26` **바로 아래**에 넣는다.

```yaml
    # 설치 채널 잡이 릴리즈 잡의 결과를 읽는다. sha256을 다시 계산하지 않는 것이
    # 요점이다 — 두 곳이 따로 계산하면 어긋나도 아무도 모른다.
    outputs:
      version: ${{ steps.version.outputs.version }}
      prerelease: ${{ steps.version.outputs.prerelease }}
      sha256: ${{ steps.checksum.outputs.sha256 }}
```

- [ ] **Step 2: 체크섬·cask 생성 스텝을 `압축` 뒤에 추가한다**

```yaml
      # 릴리즈 공개 **전**이다. make-cask.sh의 버그나 문법 오류는 여기서 죽어야
      # 하고, 그러면 아무것도 나가지 않는다. 공개 후에 죽으면 되돌릴 수 없다.
      #
      # 체크섬은 여기서 한 번만 계산해 릴리즈 자산과 cask 양쪽에 넣는다.
      - name: 체크섬과 cask 생성
        id: checksum
        run: |
          VERSION="${{ steps.version.outputs.version }}"
          ZIP="Jirarcade-${VERSION}.zip"
          shasum -a 256 "$ZIP" > "${ZIP}.sha256"
          SHA="$(awk '{print $1}' "${ZIP}.sha256")"
          echo "sha256=$SHA" >> "$GITHUB_OUTPUT"
          echo "--- ${ZIP}.sha256 ---"
          cat "${ZIP}.sha256"

          ./scripts/make-cask.sh --version "$VERSION" --sha256 "$SHA" --output jirarcade.rb
          ruby -c jirarcade.rb
          echo "--- 생성된 cask ---"
          cat jirarcade.rb
```

- [ ] **Step 3: `릴리즈 생성` 스텝이 체크섬 자산도 올리게 고친다**

`gh release create` 줄을 아래로 바꾼다. `install.sh`가 이 자산 없이는 설치를 거부하므로
zip만 올라가면 curl 경로 전체가 죽는다.

```bash
          gh release create "${GITHUB_REF_NAME}" "${ARGS[@]}" \
            "Jirarcade-${VERSION}.zip" \
            "Jirarcade-${VERSION}.zip.sha256"
```

- [ ] **Step 4: YAML 문법을 확인하고 커밋한다**

```bash
ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml"); puts "✓ release.yml 문법 유효"'
git add .github/workflows/release.yml
git commit -m "feat: 릴리즈가 체크섬과 cask를 공개 전에 만든다"
```

---

### Task 6: `release.yml` — tap 갱신과 설치 스모크

**Files:**
- Modify: `.github/workflows/release.yml` (`install-channels` 잡 추가)

**Interfaces:**
- Consumes: Task 5의 잡 출력(`version`·`prerelease`·`sha256`), Task 1의 `make-cask.sh`, Task 4의 `verify-install.sh`, Task 3의 `install.sh`
- Produces: `ahngbeom/homebrew-tap`의 `Casks/jirarcade.rb`

**선행 조건 (사람이 먼저 해야 한다):** `HOMEBREW_TAP_TOKEN` 시크릿.
fine-grained PAT, 저장소 접근은 `ahngbeom/homebrew-tap` 하나만, 권한은 **Contents: Read and write** 하나만.
`Ahngbeom/jirarcade`의 Actions secret으로 등록한다. 이 리포의 첫 시크릿이다.

- [ ] **Step 1: `install-channels` 잡을 `release` 잡 뒤에 추가한다**

파일 끝에 붙인다. 들여쓰기는 `jobs:` 아래 두 칸이다 — `release:`와 같은 높이다.

```yaml
  # 릴리즈 공개는 되돌릴 수 없다. 그 뒤의 실패에는 재실행 경로를 준다 — 별도 잡이면
  # "Re-run failed jobs"가 릴리즈를 다시 만들지 않고 이 잡만 다시 돈다.
  install-channels:
    needs: release
    runs-on: macos-26
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v7

      # 프리릴리즈는 '최신 릴리즈' 자리를 차지하지 않는다. tap도 같다 —
      # brew 사용자는 안정판만 받는다.
      - name: tap 갱신
        if: needs.release.outputs.prerelease == 'false'
        env:
          TAP_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
          VERSION: ${{ needs.release.outputs.version }}
          SHA256: ${{ needs.release.outputs.sha256 }}
        run: |
          # 조용히 건너뛰면 릴리즈가 나가도 tap이 갱신되지 않은 것을 아무도 모른다.
          # make-app.sh가 codesign 실패를 삼키지 않기로 한 것과 같은 판단이다.
          if [ -z "$TAP_TOKEN" ]; then
            echo "✗ HOMEBREW_TAP_TOKEN 시크릿이 없습니다 — tap을 갱신할 수 없습니다" >&2
            echo "  fine-grained PAT (ahngbeom/homebrew-tap, Contents: Read and write)를" >&2
            echo "  이 저장소의 Actions secret으로 등록하세요." >&2
            exit 1
          fi

          git clone "https://x-access-token:${TAP_TOKEN}@github.com/ahngbeom/homebrew-tap.git" tap
          ./scripts/make-cask.sh --version "$VERSION" --sha256 "$SHA256" --output tap/Casks/jirarcade.rb

          cd tap
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

          if git diff --quiet -- Casks/jirarcade.rb; then
            echo "▸ cask에 변경이 없습니다 — 이미 최신입니다"
            exit 0
          fi

          git add Casks/jirarcade.rb
          git commit -m "Brew cask update for jirarcade version v${VERSION}"

          # tap은 다른 프로젝트도 함께 쓴다. 동시 릴리즈가 겹치면 non-fast-forward로
          # 밀린다. 재실행으로도 회복되지만, 여기서 세 번까지는 스스로 붙여본다.
          for attempt in 1 2 3; do
            if git push; then
              echo "✓ tap 갱신 완료: v${VERSION}"
              exit 0
            fi
            echo "▸ push 충돌 — rebase 후 재시도 (${attempt}/3)"
            git pull --rebase
          done

          echo "✗ tap push에 실패했습니다" >&2
          exit 1

      # 사용자가 칠 명령을 그대로 친다. verify-bundle.sh의 압축 왕복 검사와 같은
      # 발상이다 — 받는 쪽 경로를 먼저 밟아본다.
      - name: brew 설치 스모크
        if: needs.release.outputs.prerelease == 'false'
        env:
          HOMEBREW_NO_AUTO_UPDATE: 1
          VERSION: ${{ needs.release.outputs.version }}
        run: |
          brew install --cask ahngbeom/tap/jirarcade
          ./scripts/verify-install.sh /Applications/Jirarcade.app "$VERSION"
          brew uninstall --cask jirarcade

      # 워크스페이스의 스크립트를 돌린다. raw.githubusercontent가 아니라 이 커밋의
      # 파일을 검증하려는 것이다.
      #
      # 프리릴리즈에서는 releases/latest가 이 태그를 찾지 못한다. JIRARCADE_VERSION이
      # 존재하는 이유가 이것이고, 프리릴리즈 리허설에서 curl 경로를 검증하는 방법이다.
      - name: curl 설치 스모크
        env:
          VERSION: ${{ needs.release.outputs.version }}
        run: |
          JIRARCADE_VERSION="$VERSION" bash scripts/install.sh
          ./scripts/verify-install.sh /Applications/Jirarcade.app "$VERSION"
```

- [ ] **Step 2: YAML 문법과 잡 의존을 확인한다**

```bash
ruby -ryaml -e '
  wf = YAML.load_file(".github/workflows/release.yml")
  jobs = wf["jobs"]
  raise "install-channels 잡이 없습니다" unless jobs.key?("install-channels")
  raise "needs가 release가 아닙니다"    unless jobs["install-channels"]["needs"] == "release"
  outs = jobs["release"]["outputs"]
  %w[version prerelease sha256].each { |k| raise "출력 #{k}가 없습니다" unless outs.key?(k) }
  puts "✓ release.yml 문법·잡 배선 유효"
'
```

Expected: `✓ release.yml 문법·잡 배선 유효`.

- [ ] **Step 3: 커밋한다**

```bash
git add .github/workflows/release.yml
git commit -m "feat: 릴리즈가 tap을 갱신하고 두 설치 경로를 밟아본다"
```

---

### Task 7: 문서 — 설치 안내 교체와 공증 지도 구체화

**Files:**
- Modify: `README.md` (`## 설치` 절 전체)
- Modify: `.github/release-notes-header.md` (전체)
- Modify: `scripts/make-app.sh` (`ad-hoc 서명 중…` 앞의 확장 지점 주석)

**Interfaces:**
- Consumes: Task 3의 `install.sh` 공개 URL, Task 6의 tap 경로, Task 5가 추가한 `.sha256` 자산
- Produces: 없음 (문서)

**깨뜨리면 안 되는 것:** `release.yml`의 `릴리즈 노트 작성` 스텝은 `release-notes-header.md`에
`{{VERSION}}`이 있는지 검사하고, 없으면 릴리즈를 실패시킨다. 새 본문에도 반드시 남겨야 한다.

- [ ] **Step 1: `README.md`의 `## 설치` 절을 교체한다**

기존 절(`## 설치`부터 `소스에서 직접 빌드하려면 아래를 따르세요.`까지)을 통째로 아래로 바꾼다.

````markdown
## 설치

```bash
brew install --cask ahngbeom/tap/jirarcade
```

Homebrew를 쓰지 않는다면:

```bash
curl -fsSL https://raw.githubusercontent.com/Ahngbeom/jirarcade/main/scripts/install.sh | bash
```

업데이트는 `brew upgrade --cask jirarcade`, 또는 같은 `curl` 명령을 다시 실행하면 됩니다.

<details>
<summary>이 앱은 Apple 공증을 받지 않았습니다 — 위 두 명령이 그것을 어떻게 다루는지</summary>

macOS는 인터넷에서 받은 미공증 앱에 격리 표시(`com.apple.quarantine`)를 붙이고 실행을 막으면서
"손상되었기 때문에 열 수 없습니다"라고 말합니다. 실제로 손상된 게 아니라 표시가 붙었을 뿐입니다.

- **`brew`** — Homebrew가 붙인 표시를 cask가 설치 직후 뗍니다.
- **`curl`** — 표시가 애초에 붙지 않습니다. 격리 표시는 파일을 내려받은 프로세스가 붙이는데,
  브라우저와 달리 `curl`에는 그 선언(`LSFileQuarantineEnabled`)이 없습니다. 대신 Gatekeeper의
  보증도 못 받으므로, 스크립트가 릴리즈의 `.sha256`과 대조해 무결성을 확인하고 어긋나면
  설치하지 않습니다. `sudo`는 부르지 않습니다.
- **브라우저로 zip을 직접 받았다면** 표시를 직접 떼야 합니다. macOS 15부터는 Control-클릭 →
  열기 우회가 없어져 이 명령이 유일한 출구입니다:

  ```bash
  xattr -dr com.apple.quarantine /Applications/Jirarcade.app
  ```

</details>

**알려진 동작:** 새 버전으로 올릴 때마다 macOS가 Keychain 접근을 한 번 더 묻습니다.
Keychain 항목의 접근 권한은 앱의 코드 서명에 묶이는데, 이 앱의 ad-hoc 서명은 값이 빌드마다
바뀌기 때문입니다. Developer ID로 서명하면 사라지는 마찰입니다.

소스에서 직접 빌드하려면 아래를 따르세요.
````

- [ ] **Step 2: `.github/release-notes-header.md`를 교체한다**

````markdown
## 설치

```bash
brew install --cask ahngbeom/tap/jirarcade
```

Homebrew를 쓰지 않는다면:

```bash
curl -fsSL https://raw.githubusercontent.com/Ahngbeom/jirarcade/main/scripts/install.sh | bash
```

업데이트는 `brew upgrade --cask jirarcade`, 또는 같은 `curl` 명령을 다시 실행하면 됩니다.

아래 `Jirarcade-{{VERSION}}.zip`을 직접 받아도 됩니다. 무결성은 함께 올라간 체크섬으로
확인할 수 있습니다:

```bash
shasum -a 256 -c Jirarcade-{{VERSION}}.zip.sha256
```

직접 받은 경우에는 격리 표시를 한 번 떼야 합니다 — 이 앱은 Apple 공증을 받지 않았고,
macOS 15부터는 Control-클릭 → 열기 우회가 없어졌습니다:

```bash
xattr -dr com.apple.quarantine /Applications/Jirarcade.app
```

**요구 사항:** macOS 15 이상 (Apple Silicon · Intel 모두)

**알려진 동작:** 새 버전으로 올릴 때마다 Keychain 접근을 한 번 더 묻습니다 — ad-hoc 서명의
identity가 빌드마다 바뀌기 때문입니다.
````

- [ ] **Step 3: `make-app.sh`의 공증 확장 지점 주석을 구체화한다**

기존 두 줄을 아래로 바꾼다. 코드는 건드리지 않는다 — 인증서 없이 넣는 서명 분기는
"태그를 밀기 전까지 한 번도 실행되지 않는 코드"가 되고, 이 저장소는 그것을 불신한다.

```bash
# 공증 확장 지점. Developer ID가 생기면 순서대로:
#   1. `-` 자리에 identity를 넣고 `--options runtime --timestamp`를 더한다.
#      hardened runtime과 타임스탬프가 없으면 공증이 거부된다
#   2. 번들을 ditto로 감싸 `xcrun notarytool submit --wait`에 넘긴다
#   3. `xcrun stapler staple`로 티켓을 번들에 박는다 — 이게 있어야 네트워크 없이도 열린다
#
# 그 뒤 cask의 postflight(xattr) 블록을 지운다. install.sh는 손대지 않는다 —
# 격리 표시를 떼는 로직이 애초에 없고, 부재를 확인하는 단계는 공증 이후에도 유효하다.
```

- [ ] **Step 4: 워크플로가 검사하는 자리표시자가 살아있는지 확인한다**

```bash
grep -q '{{VERSION}}' .github/release-notes-header.md \
  && echo "✓ {{VERSION}} 자리표시자 유지" \
  || { echo "✗ 자리표시자가 사라졌습니다 — 릴리즈가 실패합니다" >&2; exit 1; }

grep -c 'xattr' scripts/make-app.sh   # 주석에만 있어야 한다. 코드 변경이 없는지 확인
git diff --stat scripts/make-app.sh
```

Expected: `✓ {{VERSION}} 자리표시자 유지`. `make-app.sh`의 diff는 주석 줄만이어야 한다.

- [ ] **Step 5: 커밋한다**

```bash
git add README.md .github/release-notes-header.md scripts/make-app.sh
git commit -m "docs: 설치 안내가 명령 한 줄이 된다"
```

---

## 마무리 검증

일곱 태스크가 끝난 뒤 저장소 루트에서 한 번에 돌린다.

```bash
./scripts/test-make-cask.sh
./scripts/test-install.sh
bash -n scripts/install.sh
./scripts/make-app.sh --config release --version 0.0.0-ci --build 0
./scripts/verify-bundle.sh Packages/Jirarcade/.build/Jirarcade.app 0.0.0-ci
./scripts/verify-install.sh Packages/Jirarcade/.build/Jirarcade.app 0.0.0-ci
ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml"); YAML.load_file(".github/workflows/release.yml"); puts "✓ 워크플로 문법 유효"'
```

기본값 회귀도 본다 — 인자 없는 `./scripts/make-app.sh`가 debug·호스트 아키텍처·`0.0.0`으로
전과 똑같이 동작해야 한다.

---

## 출시 리허설 (사람이 실행 — 공개 태그를 밉니다)

여기부터는 공개된 태그를 만드므로 사용자의 승인 없이 실행하지 않는다.

- [ ] `HOMEBREW_TAP_TOKEN` 시크릿을 등록한다 (Task 6 선행 조건)
- [ ] 프리릴리즈 태그를 민다: `git tag v0.1.0-rc.2 && git push origin v0.1.0-rc.2`
  - 기대: tap 갱신과 brew 스모크는 **건너뛰고**, curl 스모크만 `JIRARCADE_VERSION`으로 돈다
  - 이 단계가 확인하는 것: 체크섬 자산 업로드, `install.sh` 전체 경로, `verify-install.sh`
- [ ] 안정 태그를 민다: `git tag v0.2.0 && git push origin v0.2.0`
  - 기대: tap에 `Casks/jirarcade.rb`가 생기고, brew·curl 스모크가 모두 통과
- [ ] 다른 사람의 맥에서 `brew install --cask ahngbeom/tap/jirarcade`로 실제 설치를 확인한다
  - 러너에서 못 보는 것: Intel 실행(선행 설계문 §10 리스크 1), Keychain 프롬프트의 실제 문구

---

## 완성 정의

설계문 §9와 같다. 태스크 대응은 아래와 같다.

| # | 조건 | 태스크 |
|---|---|---|
| 1 | `brew install --cask …`가 추가 명령 없이 실행 가능한 앱을 설치한다 | 1 · 6 |
| 2 | `brew upgrade --cask jirarcade`가 새 버전을 가져온다 | 5 · 6 |
| 3 | `curl … \| bash` 한 줄이 같은 결과를 낸다 | 3 · 7 |
| 4 | 체크섬이 어긋난 zip을 `install.sh`가 거부한다 | 2 |
| 5 | tap의 cask 버전·sha256이 릴리즈 자산과 일치한다 | 5 · 6 |
| 6 | 두 경로 모두에서 격리 표시 부재가 확인된다 | 4 · 6 |
| 7 | 프리릴리즈 태그는 tap을 갱신하지 않는다 | 6 |
| 8 | 문서의 설치 안내가 두 줄이고 Keychain 마찰이 적혀 있다 | 7 |
