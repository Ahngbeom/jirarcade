## 설치

1. 아래 `Jirarcade-{{VERSION}}.zip`을 내려받아 압축을 풉니다
2. `Jirarcade.app`을 `/Applications`로 옮깁니다
3. 터미널에서 한 번 실행합니다:

       xattr -d com.apple.quarantine /Applications/Jirarcade.app

**3번이 왜 필요한가:** 이 앱은 Apple 공증(notarization)을 받지 않았습니다.
macOS는 인터넷에서 받은 미공증 앱에 격리 표시를 붙이고 실행을 막으면서
"손상되었기 때문에 열 수 없습니다"라고 말합니다 — 실제로 손상된 게 아니라
표시가 붙었을 뿐이고, 위 명령이 그 표시를 뗍니다.

**요구 사항:** macOS 15 이상 (Apple Silicon · Intel 모두)
