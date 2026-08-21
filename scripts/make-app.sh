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
