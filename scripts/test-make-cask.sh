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
