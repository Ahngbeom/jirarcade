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
# 사용법:  ./scripts/make-app.sh          빌드 후 번들 생성
#          ./scripts/make-app.sh --open   생성 후 실행까지
set -euo pipefail

cd "$(dirname "$0")/../Packages/Jirarcade"

CONFIG="${CONFIG:-debug}"
APP=".build/Jirarcade.app"

echo "▸ 빌드 중 (${CONFIG})…"
swift build --product JirarcadeApp -c "$CONFIG"

BINARY=".build/${CONFIG}/JirarcadeApp"
if [[ ! -x "$BINARY" ]]; then
    echo "✗ 실행 파일을 찾을 수 없습니다: $BINARY" >&2
    exit 1
fi

echo "▸ 번들 구성 중…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/JirarcadeApp"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>JirarcadeApp</string>
  <key>CFBundleIdentifier</key><string>dev.jirarcade.app</string>
  <key>CFBundleName</key><string>Jirarcade</string>
  <key>CFBundleDisplayName</key><string>Jirarcade</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>

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
echo "▸ ad-hoc 서명 중…"
codesign --force --sign - "$APP" 2>/dev/null || echo "  (서명 생략 — Keychain 항목이 재확인을 요구할 수 있습니다)"

echo "✓ $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

if [[ "${1:-}" == "--open" ]]; then
    echo "▸ 실행 중…"
    open "$APP"
fi
