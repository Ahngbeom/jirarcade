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
