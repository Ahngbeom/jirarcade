# 앱 시그니처 아이콘 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Dock·Finder·⌘Tab에 뜨는 `.app` 아이콘을 만든다. 아이콘은 **팔레트의 순수 함수**여야 한다 — 손으로 그린 PNG를 커밋하는 대신 `PaletteTokens`·`Wordmark`에서 생성해, 색을 바꾸면 아이콘도 따라 바뀌게 한다.

**Architecture:** 판단(기하·색·크기별 단순화)은 `ArcadeCore/Domain/IconGeometry.swift`에 두고 테스트한다. 그리기는 `IconForge` 실행 타깃이 CoreGraphics로만 한다 — `PaletteTokens` → `ArcadeTheme`(색), `LayoutTokens` → `ArcadeMetrics`(치수)와 같은 경계다. 번들에 넣는 일은 `scripts/make-icon.sh`가, 들어갔는지 확인하는 일은 `scripts/verify-bundle.sh`가 한다.

**Tech Stack:** Swift 6.2 SwiftPM 실행 타깃 · AppKit/CoreGraphics · `iconutil` · bash

**Spec:** 별도 스펙 없음. 이 문서가 설계와 계획을 겸한다.

---

## 디자인

### 무엇을 그리나

플로어의 **업라이트 캐비닛을 그대로 줄인 것**이다. 추상 로고를 새로 만들지 않는다 — 이 앱의 정체성은 이미 캐비닛이고(아케이드 플로어), 워드마크의 경첩 A다(`Wordmark`). 아이콘·헤더·메인 화면이 같은 물건의 세 축척이 된다.

```
1024 그리드 · 824 플레이트                     16 · 32 · 64px
╭──────────────────────╮                      ╭─────╮
│                      │ ◀ 플레이트            │ ▓▓▓ │ ◀ 마퀴
│    ╭────────────╮    │   surfaceRaised       │ ▓▓▓ │ ◀ 스크린
│    │▓▓▓▓▓▓▓▓▓▓▓▓│    │   → surfaceBase 그라데이션 │ ▁▁▁ │ ◀ 조작판
│    ├────────────┤    │ ◀ 마퀴 밴드 accent     ╰─────╯
│    │▓▓▓▓██▓▓▓▓▓▓│    │
│    │▓▓▓████▓▓▓▓▓│    │ ◀ 스크린 accent +      A와 버튼은 빠진다.
│    │▓▓██▓▓██▓▓▓▓│    │   경첩 A(surfaceBase)  이 크기에서는 뭉개져
│    ├────────────┤    │                        노이즈가 될 뿐이다.
│    │  ·      ·  │    │ ◀ 조작판 surfaceRaised
│    ╰────────────╯    │   + line 버튼
╰──────────────────────╯
```

**감수하는 위험:** 아이콘을 추상 마크가 아니라 제품 자신의 가구로 만든다. Dock에서 일반적인 아케이드 캐비닛 클립아트처럼 보일 수 있다는 게 대가다. 그 대가를 상쇄하는 것이 스크린의 경첩 A다 — 캐비닛이 "아케이드"라는 장르를 말하고, A가 "이 앱"을 말한다. 둘 다 이미 저장소에 있는 것에서 나왔다.

### 색 (전부 `PaletteTokens.dark`)

| 자리 | 토큰 |
|---|---|
| 플레이트 배경 | `surfaceRaised` → `surfaceBase` 세로 그라데이션 |
| 마퀴 밴드 · 스크린 | `accent` |
| 경첩 A · 베젤 틈 | `surfaceBase` |
| 조작판 | `surfaceRaised` |
| 캐비닛 외곽선 · 버튼 | `line` |

다크 팔레트를 쓰는 이유: 아이콘 아트워크는 외관에 따라 바뀌지 않는 고정 이미지이고, 이 앱의 본래 모습이 다크다. amber가 플레이트의 약 36%를 덮어 어두운 배경화면에서도 구멍처럼 보이지 않는다.

### 크기별 단순화

한 장을 축소하지 않고 **크기마다 다시 그리는** 것이 코드로 생성하는 이유다.

| 요소 | 나타나는 크기 |
|---|---|
| 플레이트 · 캐비닛 세 밴드 | 전부 |
| 경첩 A | 64px 이상 |
| 조작판 버튼 · 상단 모서리 선 | 256px 이상 |

### 하지 않는 것

- **앱 화면 안에는 넣지 않는다.** 헤더는 이미 워드마크가 잡고 있다. 그 옆에 아이콘을 더하면 같은 말을 두 번 하는 것이고, 이 개편에서 뗀 `▨`와 같은 종류의 장식이 된다.
- **`.icns`를 커밋하지 않는다.** 번들을 만들 때 생성한다 — 커밋하면 생성기와 산출물이 갈라질 수 있고, 이 저장소에는 아직 바이너리 자산이 하나도 없다.

### 알려진 한계

macOS 26은 Icon Composer가 만드는 `.icon` 형식을 도입했다(라이트/다크/틴티드 변형을 자동으로 받는다). 고전 `.icns`도 계속 동작하지만 그 변형은 받지 못한다. 이 계획은 `.icns`로 간다 — Swift만으로 만들 수 있는 형식이고, 외부 도구나 커밋된 자산 없이 파이프라인이 닫힌다. 변형이 필요해지면 같은 `IconGeometry`에서 `.icon`을 뽑는 것이 다음 단계다. **구현 전에 러너의 `iconutil`과 macOS 26의 `.icns` 렌더링을 한 번 확인할 것.**

---

## Global Constraints

- 셸 스크립트는 `set -euo pipefail`로 시작한다
- `set -e` 아래에서 `[[ 조건 ]] && 대입`을 쓰지 않는다 — 조건이 거짓이면 스크립트가 그 자리에서 죽는다
- 사용자에게 보이는 문자열은 한국어로 쓴다 (저장소 관례)
- `IconForge`에 hex 색 리터럴을 쓰지 않는다. 색은 `PaletteTokens`에서만 온다 — `ArcadeUI`에 거는 규칙과 같다
- `IconForge`는 앱 빌드와 **별도 scratch 경로**로 빌드한다. `make-app.sh`는 유니버설 인자로 앱을 빌드하는데, 같은 scratch에 호스트 전용 빌드를 섞으면 재빌드가 churn한다
- 아이콘은 `codesign` **전에** 번들에 들어가야 한다 (`make-app.sh:123`). 뒤에 넣으면 서명이 깨진다

---

## File Structure

| 파일 | 책임 |
|---|---|
| `Sources/ArcadeCore/Domain/IconGeometry.swift` (신규) | 정규화 기하와 크기별 표시 판정. 테스트 대상 |
| `Sources/IconForge/IconForge.swift` (신규) | 기하 + 팔레트를 받아 `.iconset`에 PNG 10장을 그린다. 판단 없음 |
| `Packages/Jirarcade/Package.swift` (수정) | `IconForge` 실행 타깃 추가 |
| `Tests/ArcadeCoreTests/IconGeometryTests.swift` (신규) | 밴드 합, 플레이트 여백, 크기 임계값 |
| `Tests/ArcadeAppTests/ModuleBoundaryTests.swift` (수정) | `IconForge`에 hex 리터럴 금지 |
| `scripts/make-icon.sh` (신규) | `IconForge` + `iconutil` → `.icns` |
| `scripts/make-app.sh` (수정) | 아이콘을 `Resources/`에 넣고 `CFBundleIconFile`을 쓴다 |
| `scripts/verify-bundle.sh` (수정) | 아이콘이 실제로 들어갔는지 검사 (검사 5) |
| `README.md` (수정, 선택) | 문서 상단에 아이콘 |

**왜 `verify-bundle.sh`에 검사를 더하나:** 이 스크립트가 잡는 것은 전부 "빌드는 성공하는데 조용히 잘못된 것"이다. 아이콘 누락이 정확히 그 종류다 — `.app`은 만들어지고 zip도 나가는데 Dock에 기본 아이콘이 뜬다. 그리고 CI의 `번들 스모크` 스텝이 이미 `make-app.sh`와 `verify-bundle.sh`를 둘 다 돌리므로, 검사를 여기 두면 **모든 PR에서 아이콘 파이프라인이 공짜로 실행된다.**

---

## Task 1: 기하를 값으로 고정한다

**Files:**
- Create: `Packages/Jirarcade/Sources/ArcadeCore/Domain/IconGeometry.swift`
- Create: `Packages/Jirarcade/Tests/ArcadeCoreTests/IconGeometryTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces: `IconGeometry` — 0…1 정규화 값. Task 2가 픽셀로 곱한다.

- [x] **Step 1: 테스트를 먼저 쓴다**

  - 캐비닛 다섯 밴드(마퀴·틈·스크린·틈·조작판)의 합이 정확히 1.0이다
  - 캐비닛이 플레이트 안에 여백을 남기고 들어간다 (`x + width <= 1`, `y + height <= 1`)
  - 플레이트가 1024 캔버스에서 824이고 모서리 반지름 비율이 macOS 그리드와 맞는다
  - 표시 임계값이 순서대로다: 경첩 A(64) < 조작판 상세(256)
  - `showsHingeLetter(atPixelSize:)`가 경계값에서 정확하다 (63 거짓 / 64 참)

- [x] **Step 2: 구현한다**

`PaletteTokens`·`LayoutTokens`와 같은 자리, 같은 모양으로 둔다. 각 값에 **왜 그 값인지**를 주석으로 남긴다 — 특히 밴드 비율과 두 임계값.

**Verification:** `swift test --filter IconGeometry`

---

## Task 2: 아이콘을 그린다

**Files:**
- Create: `Packages/Jirarcade/Sources/IconForge/IconForge.swift`
- Modify: `Packages/Jirarcade/Package.swift`

**Interfaces:**
- Consumes: `IconGeometry`, `PaletteTokens`, `Wordmark.hinge`
- Produces: `swift run IconForge <iconset-경로>` — 디렉터리를 만들고 PNG 10장을 쓴다

- [x] **Step 1: 실행 타깃을 추가한다**

```swift
.executableTarget(name: "IconForge", dependencies: ["ArcadeCore"]),
```

- [x] **Step 2: 렌더러를 쓴다**

`NSBitmapImageRep` + `NSGraphicsContext`로 크기마다 한 장씩 그린다. `.iconset`이 요구하는 열 장:
`16x16`, `16x16@2x`, `32x32`, `32x32@2x`, `128x128`, `128x128@2x`, `256x256`, `256x256@2x`, `512x512`, `512x512@2x`.

경첩 글자는 `Wordmark.hinge`를 읽는다 — 문자열 `"A"`를 직접 쓰지 않는다. 서체는 워드마크와 같은 rounded heavy (`NSFontDescriptor.withDesign(.rounded)` + `.heavy`).

색은 `PaletteTokens.hex(_:in: .dark)` → `RGB` → `NSColor`로만 만든다. hex 리터럴 금지.

- [x] **Step 3: 경계 테스트를 더한다**

`ModuleBoundaryTests`에 `IconForge`의 hex 리터럴 금지를 추가한다. `viewsUseThemeTokensRatherThanColorLiterals`와 같은 정규식을 재사용한다.

**Verification:**
```
swift run IconForge /tmp/Jirarcade.iconset && ls -la /tmp/Jirarcade.iconset   # 10장
iconutil -c icns -o /tmp/Jirarcade.icns /tmp/Jirarcade.iconset                # 변환 성공
open /tmp/Jirarcade.icns                                                      # 눈으로 확인
```
**16 · 32 · 128 · 512px를 각각 눈으로 볼 것.** 작은 크기가 뭉개지면 임계값(Task 1)을 조정한다.

---

## Task 3: 번들에 넣는다

**Files:**
- Create: `scripts/make-icon.sh`
- Modify: `scripts/make-app.sh`

- [x] **Step 1: `make-icon.sh`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../Packages/Jirarcade"
OUT="${1:?사용법: make-icon.sh <출력 .icns 경로>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# 앱과 별도 scratch로 빌드한다 — make-app.sh는 유니버설로 앱을 빌드하는데
# 같은 scratch에 호스트 전용 빌드를 섞으면 매번 재빌드가 돈다.
swift build --product IconForge --scratch-path .build/iconforge
"$(swift build --product IconForge --scratch-path .build/iconforge --show-bin-path)/IconForge" \
    "$WORK/Jirarcade.iconset"
iconutil -c icns -o "$OUT" "$WORK/Jirarcade.iconset"
```

- [x] **Step 2: `make-app.sh` 수정 — 세 곳**

1. 27행의 `cd` **앞에** 스크립트 경로를 잡아 둔다. `cd` 뒤에는 상대 `$0`이 깨진다:
   ```bash
   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
   cd "$SCRIPT_DIR/../Packages/Jirarcade"
   ```
2. Info.plist 히어독(89–111행)에 키를 더한다. 확장자는 붙이지 않는다 — macOS가 `.icns`를 붙인다:
   ```
   <key>CFBundleIconFile</key><string>Jirarcade</string>
   ```
3. `codesign`(123행) **앞에** 아이콘을 넣는다:
   ```bash
   echo "▸ 아이콘 생성 중…"
   "$SCRIPT_DIR/make-icon.sh" "$APP/Contents/Resources/Jirarcade.icns"
   ```

**Verification:** `./scripts/make-app.sh --open` → Dock과 ⌘Tab에 아이콘이 뜬다. Finder에서도 확인한다 (LaunchServices 캐시 때문에 안 바뀌면 `/Applications`로 옮겼다 빼거나 `killall Dock`).

---

## Task 4: 조용히 빠지지 않게 막는다

**Files:**
- Modify: `scripts/verify-bundle.sh`

- [x] **Step 1: 검사 5를 더한다**

압축 왕복 검사(66–81행) **앞에** 넣는다:

- `Contents/Resources/Jirarcade.icns`가 있고 크기가 0이 아니다
- 파일 앞 4바이트가 `icns`다 — `iconutil`이 빈 껍데기를 쓰고 성공한 경우를 잡는다
- `CFBundleIconFile` 값이 그 파일 이름과 맞는다 — 키만 있고 파일이 다른 이름이면 Dock은 기본 아이콘을 쓴다

기존 `fail`/`pass` 헬퍼를 그대로 쓴다.

**Verification:**
```
./scripts/make-app.sh --config release --version 0.0.0-ci --build 0
./scripts/verify-bundle.sh Packages/Jirarcade/.build/Jirarcade.app 0.0.0-ci
# 아이콘을 지우고 다시 돌려 실제로 실패하는지 확인한다 — 통과만 확인하면 검사가 죽어 있어도 모른다
rm Packages/Jirarcade/.build/Jirarcade.app/Contents/Resources/Jirarcade.icns
./scripts/verify-bundle.sh Packages/Jirarcade/.build/Jirarcade.app 0.0.0-ci   # exit 1이어야 한다
```

CI(`ci.yml`의 `번들 스모크`)와 릴리즈(`release.yml`)는 **수정하지 않는다** — 둘 다 이미 이 두 스크립트를 호출한다.

---

## Task 5 (선택): README에 아이콘

**Files:**
- Create: `docs/icon-128.png`
- Modify: `README.md`

- [x] 생성된 iconset에서 `icon_128x128@2x.png`를 꺼내 `docs/icon-128.png`로 커밋하고, README 제목 옆에 넣는다.

**대가:** 저장소 첫 바이너리 자산이고, 팔레트가 바뀌면 손으로 다시 뽑아야 한다(생성 파이프라인 밖에 있으므로). GitHub에서 이 앱을 처음 보는 사람에게 아이콘을 보여줄 다른 방법이 없다는 것이 그 대가를 치르는 이유다. **원하지 않으면 이 태스크만 빼면 된다** — 앞의 넷과 독립이다.

---

## 완료 정의

- [x] `swift test` 전량 통과 (현재 539개 + 신규)
- [x] `swift run IconForge`가 열 장을 만들고 `iconutil`이 `.icns`로 바꾼다
- [x] `make-app.sh`가 만든 `.app`이 Dock·Finder·⌘Tab에 아이콘을 보여준다
- [x] `verify-bundle.sh`가 아이콘 없는 번들을 **실제로 거부한다** (지워서 확인)
- [x] 16 · 32 · 128 · 512px를 눈으로 확인했다
- [x] `codesign --verify --strict`가 아이콘을 넣은 뒤에도 통과한다
