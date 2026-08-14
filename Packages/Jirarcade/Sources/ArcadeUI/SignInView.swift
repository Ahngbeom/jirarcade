import SwiftUI
import ArcadeApp

struct SignInView: View {
    @Environment(\.arcadeTheme) private var theme
    let model: AppModel
    let message: String?

    @State private var site = ""
    @State private var email = ""
    @State private var token = ""
    @State private var isSubmitting = false

    private var canSubmit: Bool {
        !site.isEmpty && !email.isEmpty && !token.isEmpty && !isSubmitting
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
                Button(isSubmitting ? "확인 중…" : "연결") {
                    Task {
                        isSubmitting = true
                        await model.signIn(site: site, email: email, token: token)
                        isSubmitting = false
                    }
                }
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: 480)
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
