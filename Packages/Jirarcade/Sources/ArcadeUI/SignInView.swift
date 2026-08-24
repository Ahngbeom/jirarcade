import SwiftUI
import ArcadeApp

/// 로그인 화면. 기억해 둔 연결이 있으면 **토큰만** 묻는 모드로 뜬다.
///
/// 두 모드를 한 뷰에 둔 이유: 사용자에게는 같은 화면이고, 갈라 두면 "다른 계정으로
/// 연결"로 모드를 오갈 때 뷰 정체성이 바뀌어 입력한 값이 날아간다.
struct SignInView: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
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
    /// 갱신은 `phase`를 바꾸지 않으므로(`AppModel.renewToken` 참고) 진행 중임을
    /// phase로는 알 수 없다. 버튼 동작 안에서 **동기적으로** 세워 중복 제출을 막는다.
    @State private var isRenewing = false

    /// 기억한 연결이 있으면 토큰만 묻는다. 사용자가 "다른 계정으로 연결"을 고르면
    /// 모델이 힌트를 버리고, 이 값이 nil이 되어 전체 폼으로 돌아온다.
    private var hint: SignInHint? { model.signInHint }

    private var isBusy: Bool { isValidating || isRenewing }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.sectionGap) {
            JirarcadeWordmark(step: .xl)

            if let hint {
                renewalForm(hint)
            } else {
                firstConnectionForm
            }
        }
        .padding(metrics.gutter)
        .frame(maxWidth: metrics.size(.formMaxWidth))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 첫 연결

    private var firstConnectionForm: some View {
        Group {
            Text("Jira 계정을 연결해 주세요.")
                .arcadeType(.prose, .l)
                .foregroundStyle(theme.inkSecondary)

            LabeledField(label: "사이트 주소", text: $site, prompt: "example.atlassian.net")
            LabeledField(label: "이메일", text: $email, prompt: "you@example.com")
            LabeledSecureField(label: "API 토큰", text: $token)
            TokenReissueLink()

            failureText(message)

            HStack {
                Spacer()
                Button(isValidating ? "확인 중…" : "연결") {
                    Task { await model.signIn(site: site, email: email, token: token) }
                }
                .arcadeType(.prose, .m)
                .disabled(!canConnect)
                // 제출할 수 없을 때는 기본 버튼 지위 자체를 넘긴다.
                // `.defaultAction`을 항상 붙이면 macOS가 버튼을 강조색으로 칠하는데
                // `.disabled`는 글자만 흐리게 하고 배경은 그대로 둔다 — 빈 폼에서
                // 눌릴 것처럼 보이는 파란 버튼이 되고, 눌러도 아무 일이 없다.
                .keyboardShortcut(canConnect ? .defaultAction : nil)
            }
        }
    }

    private var canConnect: Bool {
        !site.isEmpty && !email.isEmpty && !token.isEmpty && !isValidating
    }

    // MARK: - 토큰 갱신

    private func renewalForm(_ hint: SignInHint) -> some View {
        Group {
            Text("기억해 둔 연결로 다시 시작합니다. 새 API 토큰만 입력하세요.")
                .arcadeType(.prose, .l)
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SavedConnectionPanel(hint: hint)

            LabeledSecureField(label: "API 토큰", text: $token)
            TokenReissueLink()

            // 직전 로그인 시도가 남긴 사유(`message`)와 갱신이 남긴 사유
            // (`tokenRenewalMessage`)는 서로 다른 경로에서 온다. 둘 다 "지금 왜 안
            // 되는가"를 말하므로 같은 자리에 띄우되, 방금 시도한 쪽을 우선한다.
            failureText(model.tokenRenewalMessage ?? message)

            HStack {
                // 계정을 바꾸는 유일한 길. 왼쪽에 두어 주 동작(연결)과 눈에 띄게 가른다.
                Button("다른 계정으로 연결") { Task { await model.forgetAccount() } }
                    .arcadeType(.prose, .s)
                    .disabled(isBusy)
                Spacer()
                Button(isBusy ? "확인 중…" : "연결") { renew() }
                    .arcadeType(.prose, .m)
                    .disabled(!canRenew)
                    .keyboardShortcut(canRenew ? .defaultAction : nil)
            }
        }
    }

    private var canRenew: Bool { !token.isEmpty && !isBusy }

    private func renew() {
        guard canRenew else { return }
        isRenewing = true
        Task {
            await model.renewToken(token)
            isRenewing = false
        }
    }

    // MARK: - 공통

    @ViewBuilder
    private func failureText(_ text: String?) -> some View {
        if let text {
            Text(text)
                .arcadeType(.prose, .s)
                .foregroundStyle(theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
