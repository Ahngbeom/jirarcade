#!/bin/bash
# 앱 아이콘을 만들어 .icns로 내놓는다.
#
# 아이콘은 커밋하지 않는다 — `IconForge`가 `PaletteTokens`·`IconGeometry`에서
# 매번 생성한다. 커밋해 두면 팔레트를 고쳤을 때 아이콘만 옛 색으로 남고, 그 어긋남은
# Dock을 눈으로 보기 전까지 아무도 모른다.
#
# 사용법: ./scripts/make-icon.sh <출력 .icns 경로>
#
# README의 `docs/icon-128.png`는 이 파이프라인 **밖**에 있는 유일한 예외다(커밋된
# 바이너리라 GitHub에서 보이려면 그래야 한다). 아이콘 기하나 팔레트를 고쳤다면
# 그 파일도 손으로 갱신할 것:
#
#   swift run --package-path Packages/Jirarcade IconForge /tmp/Jirarcade.iconset
#   cp /tmp/Jirarcade.iconset/icon_128x128@2x.png docs/icon-128.png
set -euo pipefail

cd "$(dirname "$0")/../Packages/Jirarcade"

OUT="${1:?사용법: make-icon.sh <출력 .icns 경로>}"

# 앱과 **별도 scratch**로 빌드한다. make-app.sh는 유니버설(arm64+x86_64)로 앱을
# 빌드하는데, 같은 scratch에 호스트 전용 빌드를 섞으면 두 빌드가 서로를 무효화해
# 매번 전체 재컴파일이 돈다. 아이콘 생성기는 호스트에서만 돌면 되므로 나눠 둔다.
SCRATCH=".build/iconforge"
BUILD_ARGS=(--product IconForge --scratch-path "$SCRATCH")

swift build "${BUILD_ARGS[@]}"
FORGE="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/IconForge"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$FORGE" "$WORK/Jirarcade.iconset"
iconutil -c icns -o "$OUT" "$WORK/Jirarcade.iconset"
