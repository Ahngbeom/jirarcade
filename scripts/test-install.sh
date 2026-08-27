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
