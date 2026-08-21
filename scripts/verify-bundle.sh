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
