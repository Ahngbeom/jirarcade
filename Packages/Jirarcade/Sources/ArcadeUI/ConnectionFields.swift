import SwiftUI
import ArcadeApp

/// 로그인 화면과 토큰 갱신 시트가 함께 쓰는 조각들.
///
/// 두 화면은 같은 일(연결을 세운다)을 서로 다른 시점에 한다. 폼 조각이 갈라지면
/// 사용자가 어느 경로로 왔느냐에 따라 라벨과 여백이 달라 보인다.

/// 기억해 둔 연결을 읽기 전용으로 보여준다.
///
/// 입력란이 아니라 **확인란**이다 — 바꿀 수 있는 것처럼 보이면 사용자는 여기서
/// 계정을 바꾸려 하고, 실제로 바꾸는 길("다른 계정으로 연결")을 지나친다.
struct SavedConnectionPanel: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
    let hint: SignInHint

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.tightGap) {
            row("사이트", hint.site)
            row("이메일", hint.email)
        }
        .padding(metrics.rowGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.sectionGap) {
            Text(label)
                .arcadeType(.prose, .s)
                .foregroundStyle(theme.inkTertiary)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .arcadeType(.readout, .m)
                .foregroundStyle(theme.inkPrimary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

/// 라벨이 붙은 한 줄 입력.
struct LabeledField: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
    let label: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.tightGap) {
            Text(label)
                .arcadeType(.prose, .s)
                .foregroundStyle(theme.inkTertiary)
            TextField(prompt, text: $text)
                .arcadeType(.prose, .m)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        }
    }
}

/// 토큰 입력. `SecureField`는 값을 가리므로 사용자가 붙여넣기 사고를 눈으로 확인할 수
/// 없다 — 앞뒤 공백은 `Credentials.init`이 떼어 준다.
struct LabeledSecureField: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.tightGap) {
            Text(label)
                .arcadeType(.prose, .s)
                .foregroundStyle(theme.inkTertiary)
            SecureField("", text: $text)
                .arcadeType(.prose, .m)
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// 토큰 재발급 페이지로 가는 링크. 로그인 화면과 갱신 시트가 같은 곳을 가리켜야 한다.
struct TokenReissueLink: View {
    @Environment(\.arcadeTheme) private var theme

    var body: some View {
        Link("API 토큰 발급받기", destination: AtlassianLinks.apiTokens)
            .arcadeType(.prose, .s)
            .foregroundStyle(theme.accent)
    }
}
