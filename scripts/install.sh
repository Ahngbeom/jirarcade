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
BACKUP_DIR=""

cleanup() {
    [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
    # 중단 시 BACKUP_DIR이 남아 있으면 사용자에게 그 위치를 알린다.
    # 임시 디렉터리의 백업 복사본은 시간이 지나면서 OS가 정리한다.
    # 백업을 자동으로 삭제하면 사용자의 앱이 사라진다 — 복구 기회를 잃게 된다.
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        echo "▸ 백업이 여기 있습니다: ${BACKUP_DIR}/${APP_NAME}" >&2
    fi
    return 0
}

# 백업에서 앱을 복구한다. 대상에 실패한 앱이 이미 있으면 그것을 치우고 백업을
# 넣는다. BSD mv는 기존 디렉터리 대상을 "그 안에 옮기기"로 취급하므로, 먼저
# 기존 것을 치워야 한다.
restore_backup() {
    local backup_app="$1" dest_dir="$2"
    local dest="${dest_dir}/${APP_NAME}"

    if [[ ! -d "$backup_app" ]]; then
        echo "✗ 백업 번들을 찾을 수 없습니다: $backup_app" >&2
        return 1
    fi

    # 대상에 있는 실패한 앱을 치운다.
    if [[ -e "$dest" ]]; then
        if ! rm -rf "$dest"; then
            echo "✗ 실패한 앱을 지우지 못했습니다: $dest" >&2
            echo "✗ 이전 버전으로의 복구도 실패했습니다. 이전 앱은 여기 있습니다: $backup_app" >&2
            return 1
        fi
    fi

    # 백업을 대상에 넣는다.
    if ! mv "$backup_app" "$dest"; then
        echo "✗ 이전 버전으로의 복구도 실패했습니다. 이전 앱은 여기 있습니다: $backup_app" >&2
        return 1
    fi

    echo "▸ 이전 버전으로 되돌렸습니다" >&2
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

# 검증을 통과한 번들만 여기 온다. 기존 앱을 옆으로 치우고 새것을 넣은 뒤, 실패하면
# 되돌린다. 디렉터리 교체라 진짜 원자적일 수는 없다 — 창을 좁히는 것이 할 수 있는
# 전부이고, 그 창을 0으로 만드는 것은 이 규모에서 과하다.
#
# 성공하면 기존 앱의 백업을 삭제하지 않고 전역 BACKUP_DIR에 그 경로를 기록한다.
# main이 설치 후 검증을 돌린 뒤, 그 검증이 통과해야 비로소 백업을 삭제한다.
# 검증 실패 시 main이 백업에서 복구할 수 있도록 하기 위해서다.
install_bundle() {
    local staged="$1" dest_dir="$2"
    local dest="${dest_dir}/${APP_NAME}"
    local backup_dir=""

    if [[ ! -d "$staged" ]]; then
        echo "✗ 설치할 번들이 없습니다: $staged" >&2
        return 1
    fi
    if [[ ! -d "$dest_dir" ]]; then
        echo "✗ 설치 위치가 없습니다: $dest_dir" >&2
        return 1
    fi

    if [[ -e "$dest" ]]; then
        backup_dir="$(mktemp -d)"
        if ! mv "$dest" "$backup_dir/"; then
            echo "✗ 기존 앱을 옮기지 못했습니다: $dest" >&2
            rm -rf "$backup_dir"
            return 1
        fi
    fi

    if ! mv "$staged" "$dest"; then
        echo "✗ 새 번들을 설치하지 못했습니다: $dest" >&2
        if [[ -n "$backup_dir" ]]; then
            # 여기서 bare mv를 다시 쓰면 restore_backup이 고치려던 바로 그 버그가
            # 재발한다: mv "$staged" "$dest"가 부분적으로만 실패했을 수 있어(예:
            # TMPDIR이 다른 볼륨이라 cross-device mv가 copy+delete로 풀리다 중단)
            # $dest에 이미 무언가 있을 수 있고, 그러면 BSD mv가 백업을 그 안으로
            # 옮겨 넣고도 0을 반환해 되돌렸다는 메시지가 거짓이 된다.
            if restore_backup "${backup_dir}/${APP_NAME}" "$dest_dir"; then
                rm -rf "$backup_dir"
            else
                return 1
            fi
        fi
        return 1
    fi

    # 성공했다면 백업 경로를 전역 BACKUP_DIR에 기록하고, main의 설치 후 검증이
    # 성공할 때까지 그것을 두어 필요하면 복구할 수 있게 한다.
    BACKUP_DIR="$backup_dir"
    return 0
}

main() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "✗ macOS 전용입니다" >&2
        exit 1
    fi

    local os_version
    os_version="$(sw_vers -productVersion)"
    if ! macos_version_ok "$os_version"; then
        echo "✗ macOS ${MIN_MACOS_MAJOR} 이상이 필요합니다 (현재: ${os_version})" >&2
        exit 1
    fi

    # 실행 중인 앱을 덮어쓰면 그 프로세스가 사라진 파일을 붙들고 이상하게 동작한다.
    #
    # `pgrep … && { …; exit 1; }` 형태로 쓰지 않는다 — pgrep이 아무것도 못 찾으면
    # 그 목록 전체가 실패로 평가돼 set -e가 스크립트를 죽인다. 앱이 안 켜져 있는
    # 정상 경로에서 죽는 것이다.
    if pgrep -x JirarcadeApp >/dev/null 2>&1; then
        echo "✗ Jirarcade가 실행 중입니다. 종료한 뒤 다시 실행하세요" >&2
        exit 1
    fi

    if [[ ! -w "$INSTALL_DIR" ]]; then
        echo "✗ ${INSTALL_DIR}에 쓸 권한이 없습니다" >&2
        echo "  이 스크립트는 sudo를 부르지 않습니다. 권한을 확인한 뒤 다시 실행하세요." >&2
        exit 1
    fi

    local version="${JIRARCADE_VERSION:-}"
    if [[ -z "$version" ]]; then
        local tag
        # releases/latest는 초안과 프리릴리즈를 제외한다. 프리릴리즈를 받으려면
        # JIRARCADE_VERSION으로 직접 지정해야 한다.
        tag="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | parse_tag_name || true)"
        if [[ -z "$tag" ]]; then
            echo "✗ 최신 버전을 확인하지 못했습니다 (요청 실패 또는 API 레이트 리밋)" >&2
            echo "  미인증 요청은 IP당 시간 60회로 제한됩니다. 버전을 직접 지정하면 이 요청을 건너뜁니다:" >&2
            echo "    JIRARCADE_VERSION=0.2.0 로 시작하는 형태로 다시 실행하세요" >&2
            exit 1
        fi
        version="${tag#v}"
    fi

    local base="https://github.com/${REPO}/releases/download/v${version}"
    WORKDIR="$(mktemp -d)"
    trap cleanup EXIT

    echo "▸ Jirarcade ${version} 내려받는 중…"
    curl -fL --progress-bar -o "${WORKDIR}/app.zip" "${base}/Jirarcade-${version}.zip"
    curl -fsSL -o "${WORKDIR}/app.zip.sha256" "${base}/Jirarcade-${version}.zip.sha256"

    echo "▸ 체크섬 확인 중…"
    verify_checksum "${WORKDIR}/app.zip" "${WORKDIR}/app.zip.sha256"

    # unzip이 아니라 ditto다. unzip은 확장 속성을 잃어 압축을 푼 .app의 서명이 깨진다.
    # 릴리즈 워크플로도 같은 이유로 ditto로 압축한다 — 양쪽이 짝을 이룬다.
    echo "▸ 압축 푸는 중…"
    ditto -x -k "${WORKDIR}/app.zip" "${WORKDIR}/unpacked"

    # 교체보다 검증이 먼저다. 여기서 죽으면 기존 앱이 그대로 남는다.
    echo "▸ 서명 확인 중…"
    codesign --verify --strict "${WORKDIR}/unpacked/${APP_NAME}"

    echo "▸ 설치 중…"
    install_bundle "${WORKDIR}/unpacked/${APP_NAME}" "$INSTALL_DIR"

    # 설치 후 재확인. verify-install.sh를 부르지 않는 이유: 이 스크립트는 curl로
    # 단독 실행돼 옆에 형제 파일이 없다.
    # 이 검증 단계에서 실패하면 설치 전 앱으로 되돌려야 한다.
    # 그러므로 기존 앱의 백업은 이 검증이 성공할 때까지 유지된다.
    if ! codesign --verify --strict "${INSTALL_DIR}/${APP_NAME}"; then
        echo "✗ 설치한 앱의 서명이 유효하지 않습니다" >&2
        if [[ -n "$BACKUP_DIR" ]]; then
            restore_backup "${BACKUP_DIR}/${APP_NAME}" "$INSTALL_DIR" || {
                BACKUP_DIR=""
                exit 1
            }
        fi
        BACKUP_DIR=""
        exit 1
    fi

    if xattr -p com.apple.quarantine "${INSTALL_DIR}/${APP_NAME}" >/dev/null 2>&1; then
        echo "✗ 격리 표시가 붙어 있습니다 — curl 경로에서는 나올 수 없는 상태입니다" >&2
        echo "  떼는 명령: xattr -dr com.apple.quarantine ${INSTALL_DIR}/${APP_NAME}" >&2
        if [[ -n "$BACKUP_DIR" ]]; then
            restore_backup "${BACKUP_DIR}/${APP_NAME}" "$INSTALL_DIR" || {
                BACKUP_DIR=""
                exit 1
            }
        fi
        BACKUP_DIR=""
        exit 1
    fi

    # 검증이 모두 통과했으므로 백업을 정리한다.
    [[ -n "$BACKUP_DIR" ]] && rm -rf "$BACKUP_DIR"
    BACKUP_DIR=""

    echo "✓ ${INSTALL_DIR}/${APP_NAME} (${version})"
    echo "  실행: open ${INSTALL_DIR}/${APP_NAME}"
}

# 이 파일이 source될 때는 main을 돌리지 않는다 — 테스트가 함수만 꺼내 쓴다.
# curl | bash로 실행되면 BASH_SOURCE[0]이 없으므로 $0으로 대체해 참이 된다.
# ${BASH_SOURCE[0]:-$0}의 :- 가 없으면 set -u 아래에서 unbound variable로 죽는다.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
