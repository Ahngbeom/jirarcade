import SwiftUI
import ArcadeApp

/// 만료 배너에서 여는 토큰 갱신 시트.
///
/// 전체 화면으로 바꾸지 않고 시트로 띄우는 이유: `.expired`는 미러를 계속 보여주는
/// 단계다(`Phase.showsMirror`). 화면을 갈아끼우면 사용자가 보고 있던 보드가 사라지고,
/// 갱신이 실패하면 돌아갈 자리도 없다.
struct TokenRenewalView: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
    let model: AppModel
    let hint: SignInHint
    /// 갱신에 성공했을 때 시트를 닫는다. 실패하면 사유를 띄운 채 남는다.
    let onRenewed: () -> Void
    let onCancel: () -> Void

    @State private var token = ""
    /// 버튼 동작 안에서 **동기적으로** 세운다 — `Task { }`가 다음 MainActor 턴에야
    /// 도는 사이에 Return을 두 번 눌러 `renewToken`이 겹쳐 도는 것을 막는다.
    /// `SignInView`가 `phase == .validating`으로 얻는 보호를 여기서는 이 값이 한다
    /// (갱신은 phase를 바꾸지 않으므로 phase로는 진행 중임을 알 수 없다).
    @State private var isRenewing = false

    private var canSubmit: Bool { !token.isEmpty && !isRenewing }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.sectionGap) {
            Text("토큰 갱신")
                .arcadeType(.marquee, .m)
                .foregroundStyle(theme.accent)

            Text("사이트 주소와 이메일은 그대로 씁니다. 새 API 토큰만 입력하세요.")
                .arcadeType(.prose, .m)
                .foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SavedConnectionPanel(hint: hint)

            LabeledSecureField(label: "새 API 토큰", text: $token)
            TokenReissueLink()

            if let message = model.tokenRenewalMessage {
                Text(message)
                    .arcadeType(.prose, .s)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("취소", action: onCancel)
                    .arcadeType(.prose, .m)
                    .keyboardShortcut(.cancelAction)
                Button(isRenewing ? "확인 중…" : "갱신") { submit() }
                    .arcadeType(.prose, .m)
                    .disabled(!canSubmit)
                    // 제출할 수 없을 때는 기본 버튼 지위를 넘긴다. `.disabled`는 글자만
                    // 흐리게 하고 배경은 그대로 두므로, 늘 붙여 두면 빈 폼에서 눌릴 것처럼
                    // 보이는 강조 버튼이 된다(`SignInView`가 같은 판단을 한다).
                    .keyboardShortcut(canSubmit ? .defaultAction : nil)
            }
        }
        .padding(metrics.gutter)
        .frame(maxWidth: metrics.size(.formMaxWidth), alignment: .leading)
        .background(theme.surfaceBase)
    }

    private func submit() {
        guard canSubmit else { return }
        isRenewing = true
        Task {
            let renewed = await model.renewToken(token)
            isRenewing = false
            if renewed { onRenewed() }
        }
    }
}
