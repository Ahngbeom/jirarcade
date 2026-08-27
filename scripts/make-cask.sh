#!/bin/bash
# 릴리즈 zip의 버전과 sha256을 받아 Homebrew cask 파일을 만든다.
#
# 워크플로 YAML이 아니라 스크립트로 둔 이유는 verify-bundle.sh와 같다 — 로컬과
# CI가 같은 코드를 돌아야 한다. cask 본문을 YAML 히어독에 넣으면 그 동일성은
# 첫 수정에서 깨진다.
#
# 이 스크립트는 파일을 만들기만 한다. 체크섬 계산도, tap push도 하지 않는다.
# sha256은 릴리즈 워크플로가 zip에서 한 번 계산해 이 스크립트와 릴리즈 자산
# 양쪽에 넘긴다 — 두 곳이 따로 계산하면 어긋나도 아무도 모른다.
#
# 사용법: ./scripts/make-cask.sh --version 0.2.0 --sha256 <64자리>
#         ./scripts/make-cask.sh --version 0.2.0 --sha256 <64자리> --output Casks/jirarcade.rb
#
# 옵션:
#   --version <x.y.z>   cask의 version           (필수)
#   --sha256 <해시>     zip의 sha256, 64자리 소문자 16진수 (필수)
#   --output <경로>     쓸 파일                  (기본: 표준 출력)
set -euo pipefail

VERSION=""
SHA256=""
OUTPUT=""

# 값이 필요한 옵션에 다른 옵션이 그대로 들어오면 조용히 잘못된 값이 박힌다.
# make-app.sh와 같은 방어다.
reject_flag_as_value() {
    local flag="$1" value="${2-}"
    case "$value" in
        --*) echo "✗ ${flag}에 값 대신 옵션이 왔습니다: $value" >&2; exit 2 ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) reject_flag_as_value --version "${2:-}"; VERSION="${2:?--version 값이 필요합니다}"; shift 2 ;;
        --sha256)  reject_flag_as_value --sha256 "${2:-}";  SHA256="${2:?--sha256 값이 필요합니다}";  shift 2 ;;
        --output)  reject_flag_as_value --output "${2:-}";  OUTPUT="${2:?--output 값이 필요합니다}";  shift 2 ;;
        # 조용히 무시하면 CI의 오타가 그대로 tap에 박힌다.
        *) echo "✗ 알 수 없는 옵션: $1" >&2; exit 2 ;;
    esac
done

# 릴리즈 워크플로의 태그 검증과 같은 형식이다. v0.2 같은 값이 cask의 version에
# 들어가면 url이 존재하지 않는 자산을 가리킨다.
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "✗ --version 형식이 올바르지 않습니다: '$VERSION' (예: 0.2.0, 0.2.0-rc.1)" >&2
    exit 2
fi

# shasum 출력은 소문자다. 대문자나 잘린 값이 들어오면 brew가 다운로드 후에야
# 실패하는데, 그때는 이미 릴리즈가 공개된 뒤다.
if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "✗ --sha256은 64자리 소문자 16진수여야 합니다: '$SHA256'" >&2
    exit 2
fi

# 히어독에 따옴표가 없어 ${VERSION}·${SHA256}이 확장된다. 본문의 #{version}과
# #{appdir}은 Ruby 보간이라 셸이 건드리지 않는다 — $나 백틱이 없기 때문이다.
# make-app.sh의 Info.plist 히어독과 같은 이유로 같은 방식을 쓴다.
CASK=$(cat <<CASKRB
cask "jirarcade" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/Ahngbeom/jirarcade/releases/download/v#{version}/Jirarcade-#{version}.zip",
      verified: "github.com/Ahngbeom/jirarcade/"

  name "Jirarcade"
  desc "macOS app that shows Jira tickets as an arcade game"
  homepage "https://github.com/Ahngbeom/jirarcade"

  # Info.plist의 LSMinimumSystemVersion 15.0과 같은 값이어야 한다. 어긋나면
  # cask는 설치를 허용하는데 앱이 켜지지 않는다.
  depends_on macos: ">= :sequoia"

  livecheck do
    skip "Auto-generated on release."
  end

  app "Jirarcade.app"

  # 이 앱은 공증을 받지 않았다. Homebrew는 내려받은 자산에 격리 표시를 붙이고,
  # 6.x에서 --no-quarantine 플래그가 제거돼 사용자가 뺄 방법이 없다. 여기서 뺀다.
  #
  # staged_path가 아니라 appdir인 이유: app stanza는 번들을 /Applications로 옮긴
  # 뒤에 postflight를 돌린다. staged_path는 그 시점에 비어 있어 아무 효과 없이 성공한다.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Jirarcade.app"]
  end

  zap trash: [
    "~/Library/Application Support/Jirarcade",
    "~/Library/Preferences/dev.jirarcade.app.plist",
  ]

  caveats "Jira 자격증명은 Keychain의 'Jirarcade' 항목에 남습니다 — zap이 지우지 못합니다."
end
CASKRB
)

if [[ -n "$OUTPUT" ]]; then
    printf '%s\n' "$CASK" > "$OUTPUT"
else
    printf '%s\n' "$CASK"
fi
