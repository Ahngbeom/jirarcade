# 릴리즈 CI/CD 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PR·main에서 빌드와 439개 테스트를 돌리는 검증 CI와, `v*` 태그를 밀면 유니버설 `.app`을 만들어 GitHub Release에 올리는 릴리즈 CD를 만든다.

**Architecture:** 번들을 만드는 지식은 `scripts/make-app.sh` 한 곳에 두고 워크플로는 호출만 한다. 출하 조건 검사는 `scripts/verify-bundle.sh`로 빼서 로컬과 CI가 같은 코드를 돌린다. 버전의 유일한 출처는 git 태그다.

**Tech Stack:** GitHub Actions · macOS 26 러너 · Swift 6.2 SwiftPM · bash · `gh` CLI · `ditto`/`codesign`/`lipo`/`plutil`

**Spec:** `docs/superpowers/specs/2026-08-21-release-ci-design.md`

## Global Constraints

- 러너는 `macos-26`으로 고정한다. `macos-latest`는 쓰지 않는다 (스펙 §4.3)
- `actions/checkout@v7`을 쓴다 (현재 최신 메이저)
- 패키지 루트는 리포 루트가 아니라 `Packages/Jirarcade`다
- 셸 스크립트는 `set -euo pipefail`로 시작한다
- **`set -e` 아래에서 `[[ 조건 ]] && 대입` 형태를 쓰지 않는다.** 조건이 거짓이면 문장 전체가 1을 반환해 스크립트가 그 자리에서 종료된다. 반드시 `if ... then ... fi`를 쓴다. GitHub Actions의 `run` 스텝도 기본 셸이 `bash -e`라 동일하게 적용된다
- 기본 버전은 `0.0.0`, 기본 빌드 번호는 `0`. 둘 다 0이면 "CI가 만들지 않았다"는 뜻이다 (스펙 §3.2)
- 유니버설 빌드 산출물 경로는 하드코딩하지 않고 `swift build ... --show-bin-path`로 조회한다 (스펙 §3.3)
- 압축은 `zip`이 아니라 `ditto -c -k --sequesterRsrc --keepParent`를 쓴다 (스펙 §3.5)
- 사용자에게 보이는 문자열은 한국어로 쓴다 (저장소 관례)

---

## File Structure

| 파일 | 책임 |
|---|---|
| `scripts/verify-bundle.sh` (신규) | 만들어진 `.app`이 출하 조건을 만족하는지 검사. 아키텍처·서명·버전·압축 왕복 네 가지 |
| `scripts/make-app.sh` (수정) | `.app` 번들을 만든다. 인자로 버전·구성·아키텍처를 받는다 |
| `.github/workflows/ci.yml` (신규) | PR·main 검증 |
| `.github/workflows/release.yml` (신규) | 태그 기반 릴리즈 |
| `.github/release-notes-header.md` (신규) | 릴리즈 본문 맨 위에 붙는 설치 안내 |
| `README.md` (수정) | 테스트 개수 정정, 설치 섹션 추가 |

**`verify-bundle.sh`를 왜 나누나:** 스펙 §7.1은 "로컬 검증이 워크플로가 할 검증과 동일한 명령"이어야 한다고 정했다. 명령을 양쪽에 복사하면 그 동일성은 첫 수정에서 깨진다. 스크립트로 빼면 동일성이 구조가 된다. 그리고 이 스크립트가 Task 2의 실패하는 테스트 역할을 한다 — 셸 코드에 TDD 사이클을 붙이는 방법이다.

---

## Task 1: 출하 조건 검사 스크립트

**Files:**
- Create: `scripts/verify-bundle.sh`

**Interfaces:**
- Consumes: 없음
- Produces: `./scripts/verify-bundle.sh <app-경로> <기대-버전> [--universal]` — 조건을 모두 만족하면 exit 0, 하나라도 어긋나면 각 실패를 출력하고 exit 1. Task 2의 검증 도구이자 Task 4의 워크플로 스텝이 호출하는 대상.

- [ ] **Step 1: 검사 스크립트를 작성한다**

`scripts/verify-bundle.sh`를 만든다:

```bash
#!/bin/bash
# 만들어진 .app 번들이 출하 조건을 만족하는지 검사한다.
#
# 유니버설 빌드와 codesign은 조용히 실패하는 종류다 — 빌드가 성공하고 zip도
# 만들어지는데 arm64 슬라이스만 들어 있거나 서명이 깨져 있을 수 있다. 그래서
# 릴리즈 워크플로는 업로드 전에 이 검사를 통과해야 한다.
#
# 로컬과 CI가 같은 코드를 돌게 하려고 워크플로 YAML이 아니라 스크립트로 뒀다.
# 명령을 양쪽에 복사하면 그 동일성은 첫 수정에서 깨진다.
#
# 사용법: ./scripts/verify-bundle.sh <app-경로> <기대-버전> [--universal]
set -euo pipefail

APP="${1:?사용법: verify-bundle.sh <app-경로> <기대-버전> [--universal]}"
EXPECTED_VERSION="${2:?기대 버전을 지정하세요}"

REQUIRE_UNIVERSAL=""
if [[ "${3:-}" == "--universal" ]]; then
    REQUIRE_UNIVERSAL=1
fi

FAILED=0
fail() { echo "✗ $1" >&2; FAILED=1; }
pass() { echo "✓ $1"; }

BINARY="$APP/Contents/MacOS/JirarcadeApp"
PLIST="$APP/Contents/Info.plist"

if [[ ! -x "$BINARY" ]]; then
    echo "✗ 실행 파일이 없습니다: $BINARY" >&2
    exit 1
fi

# 1. 아키텍처 — macos-26 러너는 arm64라 그냥 빌드하면 Intel 맥에서 안 켜진다.
ARCHS="$(lipo -archs "$BINARY")"
if [[ -n "$REQUIRE_UNIVERSAL" ]]; then
    if [[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]]; then
        pass "아키텍처: $ARCHS"
    else
        fail "유니버설이 아닙니다 — Intel 맥에서 실행되지 않습니다 (현재: $ARCHS)"
    fi
else
    pass "아키텍처: $ARCHS"
fi

# 2. 서명 — 없으면 받는 사람 쪽에서 차단되고, Keychain도 매번 자격증명을 다시 묻는다.
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
    pass "서명 유효"
else
    fail "codesign 검증 실패 — 받는 사람 쪽에서 '손상됨'으로 차단됩니다"
fi

# 3. 버전 주입 — 태그는 v0.3.0인데 앱은 0.0.0이라고 주장하는 상황을 막는다.
ACTUAL_VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST" 2>/dev/null || echo "<없음>")"
if [[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]]; then
    pass "버전: $ACTUAL_VERSION"
else
    fail "버전 불일치 — 기대 '$EXPECTED_VERSION', 실제 '$ACTUAL_VERSION'"
fi

# 4. 압축 왕복 — 사용자가 겪을 경로를 먼저 밟는다.
#    zip이 확장 속성을 잃으면 서명이 깨지는데 그건 압축을 푼 뒤에만 드러난다.
ROUNDTRIP="$(mktemp -d)"
trap 'rm -rf "$ROUNDTRIP"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROUNDTRIP/bundle.zip"
ditto -x -k "$ROUNDTRIP/bundle.zip" "$ROUNDTRIP/unpacked"
if codesign --verify --deep --strict "$ROUNDTRIP/unpacked/$(basename "$APP")" 2>/dev/null; then
    pass "압축 왕복 후 서명 유지"
else
    fail "압축이 서명을 깨뜨렸습니다"
fi

if [[ $FAILED -eq 1 ]]; then
    echo "" >&2
    echo "✗ 번들이 출하 조건을 만족하지 않습니다." >&2
    exit 1
fi

echo "✓ 출하 가능"
```

- [ ] **Step 2: 실행 권한을 준다**

```bash
chmod +x scripts/verify-bundle.sh
```

- [ ] **Step 3: 현재 스크립트가 만든 번들에 대해 실패하는 것을 확인한다**

이것이 이 계획의 실패하는 테스트다. 현재 `make-app.sh`는 유니버설을 만들지 못하고 버전을 `0.1`로 하드코딩한다.

```bash
./scripts/make-app.sh
./scripts/verify-bundle.sh Packages/Jirarcade/.build/Jirarcade.app 9.9.9 --universal
```

Expected: **exit 1**. 최소한 아래 두 줄이 나와야 한다.

```
✗ 유니버설이 아닙니다 — Intel 맥에서 실행되지 않습니다 (현재: arm64)
✗ 버전 불일치 — 기대 '9.9.9', 실제 '0.1'
```

서명과 압축 왕복은 통과할 것이다(현재 스크립트도 ad-hoc 서명은 한다). 통과하는 항목이 있어야 검사기 자체가 무조건 실패하는 게 아님이 확인된다.

- [ ] **Step 4: 커밋**

```bash
git add scripts/verify-bundle.sh
git commit -m "test: 번들 출하 조건 검사기

아키텍처·서명·버전 주입·압축 왕복 네 가지를 확인한다. 유니버설 빌드와
codesign은 빌드가 성공한 채로 조용히 깨지는 종류라, 릴리즈 업로드 전에
이 검사를 통과시킨다.

압축 왕복 검사는 사용자가 겪을 경로를 먼저 밟는 것이다 — zip이 확장 속성을
잃어 서명이 깨지는 실패는 압축을 푼 뒤에만 드러난다.

워크플로 YAML이 아니라 스크립트로 둔 이유는 로컬 검증과 CI 검증이 같은
코드여야 하기 때문이다. 명령을 양쪽에 복사하면 그 동일성은 첫 수정에서 깨진다.

현재 make-app.sh 산출물에 대해서는 실패한다 — 유니버설이 아니고 버전이
하드코딩돼 있다. 다음 커밋이 통과시킨다."
```

---

## Task 2: `make-app.sh` 파라미터화

**Files:**
- Modify: `scripts/make-app.sh` (전면 개정)

**Interfaces:**
- Consumes: `scripts/verify-bundle.sh` (Task 1) — 검증에 사용
- Produces: `./scripts/make-app.sh [--version <x.y.z>] [--build <n>] [--config debug|release] [--universal] [--output <dir>] [--open]` — `<output>/Jirarcade.app`을 만든다. 기본값은 `--version 0.0.0 --build 0 --config debug --output .build`이고 단일(호스트) 아키텍처다. `--output`은 `Packages/Jirarcade` 기준 상대 경로로 해석된다.

- [ ] **Step 1: 스크립트를 개정한다**

`scripts/make-app.sh`를 아래 내용으로 교체한다. 기존 주석(왜 `NSPrincipalClass`가 필요한지, 왜 ad-hoc 서명을 하는지)은 그대로 살린다 — 그게 이 파일의 값어치다.

```bash
#!/bin/bash
# Jirarcade를 실행 가능한 .app 번들로 감싼다.
#
# `swift run JirarcadeApp`으로 직접 실행하면 번들이 없어 macOS가 이 프로세스를
# 완전한 GUI 앱으로 취급하지 않는다. 그 결과 AppKit이 표준 메뉴바를 만들지 않고,
# Edit 메뉴가 없으니 ⌘C/⌘V가 동작하지 않으며 텍스트 입력 자체가 불안정해진다.
#
# Info.plist의 NSPrincipalClass가 그 열쇠다. 이 키가 있어야 AppKit이 NSApplication을
# 주 클래스로 올리고 표준 메뉴(앱·Edit·Window)를 구성한다.
#
# 사용법:  ./scripts/make-app.sh                    debug 번들
#          ./scripts/make-app.sh --open             생성 후 실행
#          ./scripts/make-app.sh --config release --universal --version 0.2.0
#
# 옵션:
#   --version <x.y.z>   CFBundleShortVersionString   (기본: 0.0.0)
#   --build <n>         CFBundleVersion              (기본: 0)
#   --config <구성>     debug | release              (기본: debug)
#   --universal         arm64 + x86_64               (기본: 호스트 아키텍처)
#   --output <dir>      번들을 놓을 디렉터리           (기본: .build)
#   --open              생성 후 실행
#
# 버전과 빌드 번호가 둘 다 0이면 CI가 만들지 않았다는 뜻이다. 릴리즈는 태그에서
# 버전을, 워크플로 실행 번호에서 빌드 번호를 받는다.
set -euo pipefail

cd "$(dirname "$0")/../Packages/Jirarcade"

VERSION="0.0.0"
BUILD="0"
CONFIG="${CONFIG:-debug}"
UNIVERSAL=""
OUTPUT=".build"
OPEN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)   VERSION="${2:?--version 값이 필요합니다}"; shift 2 ;;
        --build)     BUILD="${2:?--build 값이 필요합니다}"; shift 2 ;;
        --config)    CONFIG="${2:?--config 값이 필요합니다}"; shift 2 ;;
        --output)    OUTPUT="${2:?--output 값이 필요합니다}"; shift 2 ;;
        --universal) UNIVERSAL=1; shift ;;
        --open)      OPEN=1; shift ;;
        # 조용히 무시하면 CI에서 --version 오타가 0.0.0짜리 릴리즈로 나간다.
        *) echo "✗ 알 수 없는 옵션: $1" >&2; exit 2 ;;
    esac
done

case "$CONFIG" in
    debug|release) ;;
    *) echo "✗ --config는 debug 또는 release여야 합니다 (받은 값: $CONFIG)" >&2; exit 2 ;;
esac

APP="$OUTPUT/Jirarcade.app"

# 빌드 인자를 한 번만 만들어 빌드와 경로 조회에 똑같이 넘긴다. 유니버설 빌드는
# 산출물을 .build/apple/Products/<Config>에, 단일 아키텍처는
# .build/<triple>/<config>에 놓는다 — 인자가 갈라지면 경로도 갈라진다.
BUILD_ARGS=(--product JirarcadeApp -c "$CONFIG")
if [[ -n "$UNIVERSAL" ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

echo "▸ 빌드 중 (${CONFIG}${UNIVERSAL:+, 유니버설})…"
swift build "${BUILD_ARGS[@]}"

BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BINARY="$BIN_DIR/JirarcadeApp"
if [[ ! -x "$BINARY" ]]; then
    echo "✗ 실행 파일을 찾을 수 없습니다: $BINARY" >&2
    exit 1
fi

echo "▸ 번들 구성 중 (v${VERSION} 빌드 ${BUILD})…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/JirarcadeApp"

# 히어독에 따옴표가 없어 ${VERSION}·${BUILD}가 확장된다. 본문에 다른 $나 백틱은 없다.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>JirarcadeApp</string>
  <key>CFBundleIdentifier</key><string>dev.jirarcade.app</string>
  <key>CFBundleName</key><string>Jirarcade</string>
  <key>CFBundleDisplayName</key><string>Jirarcade</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>

  <!-- 이 키가 없으면 AppKit이 표준 메뉴바를 만들지 않아
       Edit 메뉴가 사라지고 ⌘C/⌘V·텍스트 입력이 동작하지 않는다. -->
  <key>NSPrincipalClass</key><string>NSApplication</string>

  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

# 번들에 서명이 없으면 Keychain 접근이 매 실행마다 새 앱으로 취급돼
# 저장한 자격증명을 다시 묻는다. ad-hoc 서명으로 동일 identity를 유지한다.
#
# 실패를 삼키지 않는다. ad-hoc 서명은 인증서가 필요 없어 실패할 이유가 사실상
# 없고, 그런데도 실패했다면 서명 없는 번들이 조용히 릴리즈되는 것보다 여기서
# 죽는 편이 낫다.
#
# 공증 확장 지점: Developer ID가 생기면 `-` 자리에 identity를 넣고, 아래에
# `xcrun notarytool submit --wait`와 `xcrun stapler staple`을 잇는다.
echo "▸ ad-hoc 서명 중…"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "✓ $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

if [[ -n "$OPEN" ]]; then
    echo "▸ 실행 중…"
    open "$APP"
fi
```

- [ ] **Step 2: 유니버설 릴리즈 빌드가 검사를 통과하는지 확인한다**

```bash
./scripts/make-app.sh --version 9.9.9 --build 42 --config release --universal
./scripts/verify-bundle.sh Packages/Jirarcade/.build/Jirarcade.app 9.9.9 --universal
```

Expected: **exit 0**, 다섯 줄 모두 `✓`.

```
✓ 아키텍처: x86_64 arm64
✓ 서명 유효
✓ 버전: 9.9.9
✓ 압축 왕복 후 서명 유지
✓ 출하 가능
```

- [ ] **Step 3: 기본값 회귀를 확인한다**

인자 없는 호출이 예전처럼 동작해야 한다. README에 적힌 사용법이다.

```bash
./scripts/make-app.sh
./scripts/verify-bundle.sh Packages/Jirarcade/.build/Jirarcade.app 0.0.0
plutil -extract CFBundleVersion raw Packages/Jirarcade/.build/Jirarcade.app/Contents/Info.plist
lipo -archs Packages/Jirarcade/.build/Jirarcade.app/Contents/MacOS/JirarcadeApp
```

Expected: `verify-bundle.sh`는 exit 0, `CFBundleVersion`은 `0`, `lipo -archs`는 `arm64` 하나만(유니버설 플래그를 안 줬으므로).

- [ ] **Step 4: 잘못된 인자가 거부되는지 확인한다**

```bash
./scripts/make-app.sh --verison 1.0.0 ; echo "exit=$?"
./scripts/make-app.sh --config nightly ; echo "exit=$?"
```

Expected: 둘 다 `exit=2`, 각각 `✗ 알 수 없는 옵션: --verison`과 `✗ --config는 debug 또는 release여야 합니다 (받은 값: nightly)`. 빌드는 시작되지 않아야 한다.

- [ ] **Step 5: 커밋**

```bash
git add scripts/make-app.sh
git commit -m "feat: make-app.sh가 버전과 아키텍처를 인자로 받는다

버전이 0.1/1로 하드코딩돼 있어 릴리즈마다 파일을 고쳐야 했다. --version과
--build로 받고, 기본값은 0.0.0/0으로 둔다 — 둘 다 0이면 CI가 만들지 않았다는
뜻이라 로컬 실험 빌드와 릴리즈가 앱 정보에서 구분된다.

--universal은 arm64와 x86_64를 함께 빌드한다. macos-26 러너는 arm64라 그냥
빌드하면 Intel 맥에서 아예 켜지지 않는데, macOS 15는 Intel을 여전히 지원한다.

유니버설 빌드는 산출물을 .build/apple/Products/<Config>에 놓아 단일 아키텍처
경로와 다르다. 하드코딩된 .build/<config>가 깨지므로 --show-bin-path로 조회한다.
빌드 인자 배열을 빌드와 경로 조회에 함께 넘겨, 인자가 갈라지면 경로도 갈라지는
버그를 구조적으로 막는다.

codesign 실패를 더 이상 삼키지 않는다. ad-hoc 서명은 인증서가 필요 없어
실패할 이유가 사실상 없고, 실패를 안내 문구로 바꾸면 서명 없는 번들이 조용히
릴리즈된다. 알 수 없는 옵션도 같은 이유로 거부한다 — --version 오타가
0.0.0짜리 릴리즈가 되면 안 된다."
```

---

## Task 3: 검증 CI 워크플로

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: 없음
- Produces: `macos-26` 러너에 설치된 Xcode 목록을 로그로 남긴다. Task 4의 릴리즈 워크플로가 `xcode-select`로 박을 경로를 여기서 확인한다 (스펙 §10 리스크 3).

- [ ] **Step 1: 워크플로를 작성한다**

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

# 연속 푸시가 러너를 겹쳐 잡지 않게 한다. 낡은 실행은 취소한다.
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

defaults:
  run:
    # 패키지가 리포 루트가 아니다.
    working-directory: Packages/Jirarcade

jobs:
  test:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v7

      # 툴체인을 핀으로 박지 않는다. Package.swift가 swift-tools-version 6.2를
      # 요구하므로 러너가 낮아지면 빌드가 즉시 실패하고, 올라가면 이 로그가
      # 릴리즈보다 먼저 알려준다. 릴리즈 워크플로는 반대로 명시 핀을 쓴다 —
      # CI는 "미래에 깨지나"를, 릴리즈는 "어제와 같은가"를 알고 싶기 때문이다.
      - name: 툴체인 확인
        run: |
          swift --version
          xcodebuild -version
          echo "설치된 Xcode:"
          ls /Applications | grep -i '^Xcode' || true

      - name: 빌드
        run: swift build --build-tests

      - name: 테스트
        run: swift test
```

- [ ] **Step 2: YAML 문법을 검사한다**

```bash
if command -v actionlint >/dev/null; then actionlint; else echo "actionlint 없음 — 건너뜀"; fi
```

`actionlint`가 없으면 `brew install actionlint`로 설치해 돌린다. 설치가 불가하면 건너뛰고 그 사실을 커밋 메시지에 남기지 말고 최종 보고에만 적는다.

- [ ] **Step 3: 커밋하고 푸시해 실제로 돌린다**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: PR·main에서 빌드와 테스트를 돌린다

macos-26으로 고정한다. 기본 Xcode 26.2가 개발 환경의 Swift 6.2.3과 같고,
macos-latest는 지금 macos-26을 가리키지만 언젠가 조용히 움직인다.

툴체인은 핀으로 박지 않고 버전을 로그로 남긴다. Package.swift가 6.2를
요구하므로 낮아지면 빌드가 즉시 실패하고, 올라가면 이 로그가 릴리즈보다
먼저 알려준다.

.build 캐시는 넣지 않았다. 외부 의존이 0개라 받아올 것이 없고, 캐시가
무효화될 때 생기는 이상한 실패를 디버깅하는 비용이 절약되는 몇 분보다 크다."
git push -u origin HEAD
```

- [ ] **Step 4: 실행 결과와 Xcode 경로를 확인한다**

```bash
gh run watch --exit-status
gh run view --log | grep -A5 "설치된 Xcode:"
```

Expected: 워크플로 성공. **그리고 로그에서 Xcode 26.2의 실제 디렉터리 이름을 받아 적는다** (예: `Xcode_26.2.app`). Task 4에서 이 경로를 쓴다. 이름이 예상과 다르면 Task 4의 `xcode-select` 경로를 실측값으로 바꾼다.

Expected: 테스트 스텝에 `Test run with 439 tests` 및 종료 코드 0.

---

## Task 4: 릴리즈 워크플로

**Files:**
- Create: `.github/release-notes-header.md`
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes:
  - `./scripts/make-app.sh --version <v> --build <n> --config release --universal` (Task 2) → `Packages/Jirarcade/.build/Jirarcade.app`
  - `./scripts/verify-bundle.sh <app> <v> --universal` (Task 1) → exit 0/1
  - Task 3에서 확인한 Xcode 디렉터리 이름
- Produces: `v*` 태그 푸시 시 `Jirarcade-<version>.zip`이 붙은 GitHub Release

- [ ] **Step 1: 설치 안내를 작성한다**

`.github/release-notes-header.md`. `{{VERSION}}`은 워크플로가 치환한다.

```markdown
## 설치

1. 아래 `Jirarcade-{{VERSION}}.zip`을 내려받아 압축을 풉니다
2. `Jirarcade.app`을 `/Applications`로 옮깁니다
3. 터미널에서 한 번 실행합니다:

       xattr -d com.apple.quarantine /Applications/Jirarcade.app

**3번이 왜 필요한가:** 이 앱은 Apple 공증(notarization)을 받지 않았습니다.
macOS는 인터넷에서 받은 미공증 앱에 격리 표시를 붙이고 실행을 막으면서
"손상되었기 때문에 열 수 없습니다"라고 말합니다 — 실제로 손상된 게 아니라
표시가 붙었을 뿐이고, 위 명령이 그 표시를 뗍니다.

**요구 사항:** macOS 15 이상 (Apple Silicon · Intel 모두)
```

- [ ] **Step 2: 릴리즈 워크플로를 작성한다**

`.github/workflows/release.yml`. `XCODE_PATH`는 Task 3 Step 4에서 확인한 실제 경로로 맞춘다.

```yaml
name: Release

on:
  push:
    tags: ['v*']

permissions:
  # 릴리즈 생성에 필요한 최소 권한. 그 외는 부여하지 않는다.
  contents: write

jobs:
  release:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v7

      # 릴리즈는 재현성이 우선이라 툴체인을 명시적으로 박는다. 경로가 사라지면
      # 즉시 실패하는데, 조용히 다른 버전으로 빌드되는 것보다 낫다.
      - name: Xcode 고정
        run: |
          sudo xcode-select -s /Applications/Xcode_26.2.app
          swift --version

      # 형식이 어긋난 태그는 여기서 죽인다. v0.2 같은 값이 그대로
      # CFBundleShortVersionString에 들어가면 나중에 조용히 이상해진다.
      - name: 태그 검증 및 버전 추출
        id: version
        run: |
          TAG="${GITHUB_REF_NAME}"
          if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
            echo "✗ 태그 형식이 올바르지 않습니다: $TAG (예: v0.2.0, v0.2.0-rc.1)" >&2
            exit 1
          fi
          VERSION="${TAG#v}"
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          # 프리릴리즈는 '최신 릴리즈' 자리를 차지하지 않는다.
          if [[ "$VERSION" == *-* ]]; then
            echo "prerelease=true" >> "$GITHUB_OUTPUT"
          else
            echo "prerelease=false" >> "$GITHUB_OUTPUT"
          fi

      # 태그는 임의의 커밋에 붙을 수 있다 — CI를 통과한 적 없는 커밋에도.
      # 게이트는 릴리즈되는 바로 그 트리에서 서야 의미가 있다.
      - name: 테스트 게이트
        working-directory: Packages/Jirarcade
        run: swift test

      - name: 번들 생성
        run: |
          ./scripts/make-app.sh \
            --version "${{ steps.version.outputs.version }}" \
            --build "${{ github.run_number }}" \
            --config release \
            --universal

      - name: 출하 전 검증
        run: |
          ./scripts/verify-bundle.sh \
            Packages/Jirarcade/.build/Jirarcade.app \
            "${{ steps.version.outputs.version }}" \
            --universal

      # zip이 아니라 ditto다. zip은 확장 속성과 심볼릭 링크를 잃어
      # 압축을 푼 .app의 서명이 깨진다.
      - name: 압축
        run: |
          ditto -c -k --sequesterRsrc --keepParent \
            Packages/Jirarcade/.build/Jirarcade.app \
            "Jirarcade-${{ steps.version.outputs.version }}.zip"

      # --notes-file과 --generate-notes를 함께 넘겼을 때 합쳐지는 방식이
      # 문서화돼 있지 않아, 생성 노트를 API로 직접 받아 헤더 뒤에 붙인다.
      - name: 릴리즈 노트 작성
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          VERSION="${{ steps.version.outputs.version }}"
          sed "s/{{VERSION}}/${VERSION}/g" .github/release-notes-header.md > notes.md
          printf '\n---\n\n' >> notes.md
          gh api "repos/${GITHUB_REPOSITORY}/releases/generate-notes" \
            -f tag_name="${GITHUB_REF_NAME}" \
            --jq '.body' >> notes.md
          echo "--- 생성된 릴리즈 본문 ---"
          cat notes.md

      - name: 릴리즈 생성
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          VERSION="${{ steps.version.outputs.version }}"
          ARGS=(--title "Jirarcade ${VERSION}" --notes-file notes.md)
          if [[ "${{ steps.version.outputs.prerelease }}" == "true" ]]; then
            ARGS+=(--prerelease)
          fi
          gh release create "${GITHUB_REF_NAME}" "${ARGS[@]}" "Jirarcade-${VERSION}.zip"
```

- [ ] **Step 3: YAML 문법을 검사한다**

```bash
if command -v actionlint >/dev/null; then actionlint; else echo "actionlint 없음 — 건너뜀"; fi
```

Expected: 경고 없음.

- [ ] **Step 4: 태그 검증 정규식을 로컬에서 확인한다**

워크플로를 돌리지 않고 정규식만 떼어 확인한다. 잘못된 태그가 통과하면 릴리즈가 이상한 버전으로 나간다.

```bash
for TAG in v0.2.0 v0.2.0-rc.1 v10.0.1 v0.2 0.2.0 vX.Y.Z v0.2.0.1; do
  if [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "통과: $TAG"
  else
    echo "거부: $TAG"
  fi
done
```

Expected:

```
통과: v0.2.0
통과: v0.2.0-rc.1
통과: v10.0.1
거부: v0.2
거부: 0.2.0
거부: vX.Y.Z
거부: v0.2.0.1
```

- [ ] **Step 5: 커밋하고 푸시한다**

```bash
git add .github/release-notes-header.md .github/workflows/release.yml
git commit -m "ci: v* 태그를 밀면 릴리즈를 만든다

태그가 버전의 유일한 출처다. 태그에서 CFBundleShortVersionString을,
워크플로 실행 번호에서 CFBundleVersion을 받는다. 형식이 어긋난 태그는
빌드 전에 거부한다 — v0.2 같은 값이 앱 버전이 되면 나중에 조용히 이상해진다.

릴리즈에서도 테스트를 다시 돈다. 태그는 임의의 커밋에 붙을 수 있어 CI 통과를
보증하지 않는다. 게이트는 릴리즈되는 그 트리에서 서야 의미가 있다.

업로드 전에 verify-bundle.sh로 아키텍처·서명·버전·압축 왕복을 확인한다.
유니버설 빌드와 codesign은 빌드가 성공한 채로 조용히 깨지는 종류다.

수령자에게 Apple Developer 계정이 없어 공증을 못 하므로, 릴리즈 본문에
격리 속성 제거 안내를 항상 붙인다. 이게 없으면 받는 사람은 '손상된 앱'
메시지만 본다. 안내는 YAML 히어독이 아니라 파일로 두어 수정이 diff로 남게 했다.

툴체인은 CI와 반대로 명시 핀을 쓴다. CI는 '미래에 깨지나'를, 릴리즈는
'어제와 같은가'를 알고 싶다."
git push
```

---

## Task 5: README 갱신

**Files:**
- Modify: `README.md:70`, `README.md:87` (테스트 개수), `README.md:42` 앞 (설치 섹션)

**Interfaces:**
- Consumes: Task 4의 릴리즈 산출물 이름 규칙 (`Jirarcade-<version>.zip`)
- Produces: 없음

- [ ] **Step 1: 테스트 개수를 실측값으로 고친다**

실측: `swift test`가 **439개**를 0.8초에 통과한다. README는 백필 작업 이전 값인 221을 두 곳에서 말한다.

70행:
```
221개 테스트가 약 0.2초에 끝납니다. 규칙이 순수 함수이고
```
→
```
439개 테스트가 1초 안에 끝납니다. 규칙이 순수 함수이고
```

87행:
```
- **`ArcadeApp`은 SwiftUI를 모릅니다.** 테스트하는 것과 눈으로 확인하는 것의 경계이고, 그래서 221개 테스트가 화면 없이 돕니다
```
→
```
- **`ArcadeApp`은 SwiftUI를 모릅니다.** 테스트하는 것과 눈으로 확인하는 것의 경계이고, 그래서 439개 테스트가 화면 없이 돕니다
```

- [ ] **Step 2: 개수가 남아 있지 않은지 확인한다**

```bash
grep -n "221개" README.md ; echo "exit=$?"
```

Expected: 출력 없음, `exit=1`.

- [ ] **Step 3: 설치 섹션을 추가한다**

현재 README에는 소스에서 빌드하는 방법만 있고 받아서 쓰는 방법이 없다. `## 요구 사항`(36행)과 `## 실행`(42행) 사이에 넣는다 — 요구 사항을 읽은 직후가 "그래서 어떻게 받나"를 묻는 자리다.

````markdown
## 설치

[릴리즈 페이지](https://github.com/Ahngbeom/jirarcade/releases)에서 최신 `Jirarcade-x.y.z.zip`을
내려받아 압축을 풀고 `Jirarcade.app`을 `/Applications`로 옮긴 뒤, 터미널에서 한 번 실행합니다:

```bash
xattr -d com.apple.quarantine /Applications/Jirarcade.app
```

이 앱은 Apple 공증(notarization)을 받지 않았습니다. macOS는 인터넷에서 받은 미공증 앱에
격리 표시를 붙이고 실행을 막으면서 "손상되었기 때문에 열 수 없습니다"라고 말합니다 —
실제로 손상된 게 아니라 표시가 붙었을 뿐이고, 위 명령이 그 표시를 뗍니다.

소스에서 직접 빌드하려면 아래를 따르세요.
````

`## 요구 사항`의 Swift·Xcode 항목은 소스 빌드에만 해당하므로, 설치 섹션을 넣은 뒤 그 항목 앞에
"(소스에서 빌드할 때만)"을 덧붙인다.

- [ ] **Step 4: 링크와 마크다운을 확인한다**

```bash
grep -n "releases\|xattr\|439개" README.md
```

Expected: 릴리즈 링크 1개, `xattr` 1개, `439개` 2개.

- [ ] **Step 5: 커밋**

```bash
git add README.md
git commit -m "docs: 테스트 개수 정정과 설치 섹션

221개는 백필 작업 이전 값이다. 실측하면 439개가 0.8초에 통과한다.

받아서 쓰는 방법이 README에 없었다 — 소스 빌드 방법만 있었다. 릴리즈가
생겼으므로 내려받기 경로와 격리 속성 제거 안내를 넣는다. 공증을 받지
않았다는 사실과 그래서 왜 그 명령이 필요한지를 함께 적는다."
```

---

## Task 6: 프리릴리즈 태그로 실제 리허설

**Files:** 없음 (실행만)

**Interfaces:**
- Consumes: Task 1~5 전부
- Produces: 검증된 릴리즈 파이프라인

이것이 유일한 진짜 end-to-end 검증이다. **워크플로 파일은 태그된 커밋에 존재하기만 하면 되므로 main 병합 전에 브랜치에서 리허설할 수 있다.**

- [ ] **Step 1: 프리릴리즈 태그를 민다**

```bash
git tag v0.0.1-rc.1
git push origin v0.0.1-rc.1
```

`-`가 있으므로 워크플로가 `--prerelease`를 붙이고, "최신 릴리즈" 자리를 차지하지 않는다.

- [ ] **Step 2: 워크플로를 지켜본다**

```bash
gh run watch --exit-status
```

Expected: 모든 스텝 성공. 특히 `출하 전 검증`에서 다섯 줄 `✓`.

- [ ] **Step 3: 릴리즈 본문과 첨부를 확인한다**

```bash
gh release view v0.0.1-rc.1
```

Expected:
- prerelease로 표시됨
- 자산에 `Jirarcade-0.0.1-rc.1.zip`
- 본문 맨 위에 설치 안내(버전이 `0.0.1-rc.1`로 치환되어 있어야 하고 `{{VERSION}}`이 남아 있으면 안 된다), 그 아래 `---`, 그 아래 자동 생성된 커밋·PR 목록

- [ ] **Step 4: 받는 사람 경로를 그대로 밟는다**

```bash
cd "$(mktemp -d)"
gh release download v0.0.1-rc.1 --repo Ahngbeom/jirarcade
ditto -x -k Jirarcade-0.0.1-rc.1.zip .
lipo -archs Jirarcade.app/Contents/MacOS/JirarcadeApp
plutil -extract CFBundleShortVersionString raw Jirarcade.app/Contents/Info.plist
plutil -extract CFBundleVersion raw Jirarcade.app/Contents/Info.plist
codesign --verify --deep --strict Jirarcade.app && echo "서명 OK"
xattr -d com.apple.quarantine Jirarcade.app 2>/dev/null || true
open Jirarcade.app
```

Expected: `x86_64 arm64`, `0.0.1-rc.1`, 워크플로 실행 번호와 같은 숫자, `서명 OK`, 그리고 **앱 창이 실제로 뜨고 텍스트 입력이 동작한다**(⌘V가 먹는지 확인 — `NSPrincipalClass`가 살아 있다는 증거다).

- [ ] **Step 5: 리허설 흔적을 지운다**

```bash
gh release delete v0.0.1-rc.1 --yes --cleanup-tag
git fetch --prune --prune-tags origin
git tag -d v0.0.1-rc.1 2>/dev/null || true
```

Expected: `gh release list`에 남아 있지 않고, `git tag`도 비어 있다.

- [ ] **Step 6: 실행 기록을 남긴다**

`docs/superpowers/records/2026-08-21-release-ci-execution.md`를 쓴다. 저장소 관례이며, `2026-08-14-app-shell-execution.md`가 형식의 본보기다. 담을 것:

- 리허설에서 실제로 드러난 것 — 러너의 Xcode 경로 실측값, `gh api generate-notes` 본문이 기대대로 붙었는지, 예상과 달랐던 스텝
- 스펙 §10의 리스크 중 해소된 것과 남은 것 (리스크 1 "Intel 실행 실물 검증 불가"는 계속 남는다)
- 다음 사람이 첫 정식 릴리즈를 낼 때 밟을 절차 세 줄

```bash
git add docs/superpowers/records/2026-08-21-release-ci-execution.md
git commit -m "docs: 릴리즈 CI 실행 기록"
git push
```

---

## Self-Review

**스펙 커버리지**

| 스펙 | 태스크 |
|---|---|
| §2 make-app.sh를 단일 진실로 | Task 2 |
| §3.1 인터페이스 | Task 2 Step 1 |
| §3.2 버전 출처 | Task 2 Step 1·3 |
| §3.3 `--show-bin-path` | Task 2 Step 1, 검증은 Task 1 Step 3 / Task 2 Step 2 |
| §3.4 codesign 실패 노출 | Task 2 Step 1 |
| §3.5 zip은 워크플로가 | Task 4 Step 2 (`ditto`) |
| §4.1 검증 CI | Task 3 |
| §4.2 릴리즈 CD | Task 4 |
| §4.3 툴체인 정책 | Task 3 Step 1 (핀 없음) · Task 4 Step 2 (핀) |
| §4.4 출하 전 검증 4종 | Task 1 |
| §4.5 릴리즈에서 테스트 재실행 | Task 4 Step 2 |
| §5 산출물·설치 안내 | Task 4 Step 1·2 |
| §6.1 README 테스트 개수 | Task 5 Step 1 |
| §6.2 README 설치 섹션 | Task 5 Step 3 |
| §6.3 공증 확장 지점 주석 | Task 2 Step 1 |
| §7.1 로컬 스크립트 검증 | Task 2 Step 2~4 |
| §7.2 actionlint | Task 3 Step 2 · Task 4 Step 3 |
| §7.3 리허설 | Task 6 |
| §10 리스크 2 (노트 조합) | Task 4 Step 2 — API 경로로 해소 |
| §10 리스크 3 (Xcode 경로) | Task 3 Step 4에서 실측 → Task 4에 반영 |

빠진 스펙 항목 없음.

**타입·이름 일관성**

- `verify-bundle.sh <app> <version> [--universal]` — Task 1에서 정의, Task 2 Step 2·3과 Task 4 Step 2에서 같은 순서로 호출
- `make-app.sh`의 플래그 이름 — Task 2에서 정의, Task 4 Step 2 호출과 일치
- 번들 경로 `Packages/Jirarcade/.build/Jirarcade.app` — Task 2의 기본 `--output .build`(패키지 기준)와 일치
- zip 이름 `Jirarcade-<version>.zip` — Task 4 Step 2 생성, Step 1 헤더 문구, Task 5 README, Task 6 Step 4 다운로드에서 동일
- `{{VERSION}}` 토큰 — Task 4 Step 1에서 정의, Step 2의 `sed`가 치환, Task 6 Step 3에서 잔존 여부 확인

**플레이스홀더 스캔**

`Xcode_26.2.app` 경로만 Task 3 Step 4의 실측에 의존한다. 이는 미정 값이 아니라 **확인 절차가 지정된 값**이며, 확인 시점과 반영 위치가 태스크로 박혀 있다.
