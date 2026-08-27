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
