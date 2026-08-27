## 설치

```bash
brew install --cask ahngbeom/tap/jirarcade
```

Homebrew를 쓰지 않는다면:

```bash
curl -fsSL https://raw.githubusercontent.com/Ahngbeom/jirarcade/main/scripts/install.sh | bash
```

업데이트는 `brew upgrade --cask jirarcade`, 또는 같은 `curl` 명령을 다시 실행하면 됩니다.

아래 `Jirarcade-{{VERSION}}.zip`을 직접 받아도 됩니다. 무결성은 함께 올라간 체크섬으로
확인할 수 있습니다:

```bash
shasum -a 256 -c Jirarcade-{{VERSION}}.zip.sha256
```

직접 받은 경우에는 격리 표시를 한 번 떼야 합니다 — 이 앱은 Apple 공증을 받지 않았고,
macOS 15부터는 Control-클릭 → 열기 우회가 없어졌습니다:

```bash
xattr -dr com.apple.quarantine /Applications/Jirarcade.app
```

**요구 사항:** macOS 15 이상 (Apple Silicon · Intel 모두)

**알려진 동작:** 새 버전으로 올릴 때마다 Keychain 접근을 한 번 더 묻습니다 — ad-hoc 서명의
identity가 빌드마다 바뀌기 때문입니다.
