import SwiftUI
import ArcadeApp

public struct RootView: View {
    @Environment(\.colorScheme) private var colorScheme
    private let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        RootContent(model: model)
            .arcadeTheme(model.appearancePreference, systemIsDark: colorScheme == .dark)
    }
}

private struct RootContent: View {
    @Environment(\.arcadeTheme) private var theme
    let model: AppModel

    var body: some View {
        content
            .frame(minWidth: 720, minHeight: 480)
            .background(theme.surfaceBase)
            .task { await model.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .launching:
            ProgressView().tint(theme.accent)
        case .signedOut, .validating:
            // 두 케이스를 한 분기에 묶어야 SignInView가 같은 뷰 정체성을 유지한다 — 그래야
            // signIn()이 phase를 .validating으로 바꿔도 SwiftUI가 SignInView를 허물고 새로
            // 만들지 않는다. 따로 두면 사용자가 입력한 site/email/token(@State)이 검증
            // 시작과 동시에 날아가고, 실패해서 .signedOut으로 돌아왔을 때 빈 폼이 새로 뜬다.
            SignInView(model: model, message: signedOutMessage, isValidating: model.phase == .validating)
        case .mappingWorkflow(let candidates):
            placeholder("WORKFLOW MAPPING", detail: "\(candidates.count)개 상태")
        case .ready, .expired:
            placeholder("ARCADE FLOOR", detail: "관측 \(model.observationDays)일차")
        }
    }

    /// `.signedOut`일 때만 메시지가 있다. `.validating` 중에는 이전 오류를 지운다.
    private var signedOutMessage: String? {
        if case .signedOut(let message) = model.phase { return message }
        return nil
    }

    private func placeholder(_ title: String, detail: String?) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.accent)
            if let detail {
                Text(detail).foregroundStyle(theme.inkSecondary)
            }
        }
    }
}
