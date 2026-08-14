import SwiftUI
import ArcadeApp

struct SignInView: View {
    @Environment(\.arcadeTheme) private var theme
    let model: AppModel
    let message: String?
    /// `model.phase == .validating`를 그대로 옮겨온 값. 별도의 `@State`로 "제출 중"을
    /// 추적하면 `Task { }`가 다음 MainActor 턴에야 실행되는 사이에 두 번째 탭/Return이
    /// 겹쳐 `model.signIn`이 동시에 두 번 실행될 수 있다. `AppModel.signIn`은 `phase`를
    /// 첫 `await` 이전에 동기적으로 `.validating`으로 바꾸므로, 이 값을 그대로 읽으면
    /// 그 틈이 아예 생기지 않는다.
    let isValidating: Bool

    @State private var site = ""
    @State private var email = ""
    @State private var token = ""

    private var canSubmit: Bool {
        !site.isEmpty && !email.isEmpty && !token.isEmpty && !isValidating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("JIRARCADE")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.accent)

            Text("Jira 계정을 연결해 주세요.")
                .foregroundStyle(theme.inkSecondary)

            field("사이트 주소", text: $site, prompt: "example.atlassian.net")
            field("이메일", text: $email, prompt: "you@example.com")
            secureField("API 토큰")

            Link("API 토큰 발급받기",
                 destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                .foregroundStyle(theme.accent)
                .font(.callout)

            if let message {
                Text(message)
                    .foregroundStyle(theme.danger)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button(isValidating ? "확인 중…" : "연결") {
                    Task { await model.signIn(site: site, email: email, token: token) }
                }
                .disabled(!canSubmit)
                // 제출할 수 없을 때는 기본 버튼 지위 자체를 넘긴다.
                // `.defaultAction`을 항상 붙이면 macOS가 버튼을 강조색으로 칠하는데
                // `.disabled`는 글자만 흐리게 하고 배경은 그대로 둔다 — 빈 폼에서
                // 눌릴 것처럼 보이는 파란 버튼이 되고, 눌러도 아무 일이 없다.
                .keyboardShortcut(canSubmit ? .defaultAction : nil)
            }
        }
        .padding(40)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(theme.inkTertiary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        }
    }

    private func secureField(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(theme.inkTertiary)
            SecureField("", text: $token)
                .textFieldStyle(.roundedBorder)
        }
    }
}
