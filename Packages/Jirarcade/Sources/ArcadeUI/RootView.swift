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
        VStack(spacing: 0) {
            if model.phase == .expired {
                expiredBanner
            }
            if let warning = model.credentialSaveWarning {
                credentialSaveWarningBanner(warning)
            }
            content
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(theme.surfaceBase)
        .task { await model.start() }
        .onChange(of: model.phase) { old, new in
            // `.ready`로 들어오는 경로는 두 가지다: (1) 로그인/매핑을 막 끝내고 처음
            // ready가 된 경우 — 동기화 루프를 이제 막 시작해야 한다. (2) `.expired`에서
            // 회복한 경우 — performSync()가 이미 동기화를 막 끝내고 phase만 되돌린
            // 것이므로(AppModel.swift 재인증 없이 회복하는 분기) 루프는 이미 돌고 있다.
            // 여기서 또 startSyncing()을 부르면 타이머를 취소하고 다시 만들어 백오프
            // 상태를 리셋하고, syncNow()는 방금 끝난 동기화를 곧장 한 번 더 보낸다.
            // 그래서 이전 phase가 `.expired`가 아닐 때만 "처음 ready가 됐다"고 본다.
            if new == .ready && old != .expired {
                model.startSyncing()
                Task { await model.syncNow(reason: .manual) }
            }
        }
    }

    private var expiredBanner: some View {
        HStack(spacing: 8) {
            Text("토큰이 만료됐습니다. 다시 로그인해 주세요.")
                .font(.callout)
                .foregroundStyle(theme.surfaceBase)
            Spacer()
            Button("로그아웃") { Task { await model.signOut() } }
                .font(.callout)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(theme.danger)
    }

    /// 로그인은 성공했지만 자격증명을 Keychain에 저장하지 못했을 때만 뜬다.
    /// `phase`는 이미 `.ready`이므로 에러가 아니라 경고다 — 지금 세션은 정상 동작하고,
    /// 다음 실행에서 로그인이 풀릴 수 있다는 사실만 알려준다. 로그인 화면은 이 시점에
    /// 이미 사라진 뒤라 여기 말고는 보여줄 곳이 없다.
    private func credentialSaveWarningBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Text("⚠ \(message)")
                .font(.callout)
                .foregroundStyle(theme.surfaceBase)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(theme.danger)
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
            WorkflowMappingView(model: model, candidates: candidates)
        case .ready, .expired:
            ArcadeFloorView(model: model)
        }
    }

    /// `.signedOut`일 때만 메시지가 있다. `.validating` 중에는 이전 오류를 지운다.
    private var signedOutMessage: String? {
        if case .signedOut(let message) = model.phase { return message }
        return nil
    }
}
