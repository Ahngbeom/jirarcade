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
        case .launching, .validating:
            ProgressView().tint(theme.accent)
        case .signedOut(let message):
            SignInView(model: model, message: message)
        case .mappingWorkflow(let candidates):
            placeholder("WORKFLOW MAPPING", detail: "\(candidates.count)개 상태")
        case .ready, .expired:
            placeholder("ARCADE FLOOR", detail: "관측 \(model.observationDays)일차")
        }
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
