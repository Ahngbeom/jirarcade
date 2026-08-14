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
                warningBanner(warning)
            }
            if let warning = model.workflowSaveWarning {
                warningBanner(warning)
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
            //
            // 이 판별이 성립하는 건 지금 AppModel의 모양에 기대고 있다 — 다음 세 가지가
            // 전부 참이어야 한다: (a) `phase = .expired`를 세팅하는 곳은 정확히 두 군데
            // (validate()의 unauthorized catch, performSync()의 unauthorized catch)뿐이고,
            // (b) 그중 client를 nil로 남기는 쪽(validate(persistOnSuccess: false))은
            // performSync()를 통해 `.ready`로 회복하는 일이 없으며(guard let client에서
            // 막힘), (c) startSyncing()을 부르는 곳은 이 한 곳뿐이다. 셋 중 하나라도
            // 깨지면 — `.expired`로 가는 세 번째 경로가 생기거나, startSyncing()을 부르는
            // 곳이 늘거나, 첫 번째 catch에서 client를 세팅하게 되면 — 이 조건은 조용히
            // 틀려진다. 이 줄을 건드리기 전에 위 셋을 다시 확인할 것.
            if new == .ready && old != .expired {
                model.startSyncing()
                Task { await model.syncNow(reason: .manual) }
            }
        }
    }

    /// 재로그인이 필요한, **막는** 배너다. danger를 채움으로 써서 "지금은 못 쓴다"는
    /// 무게를 준다 — 아래 `warningBanner`(M5)와 구조적으로 다른 대접이어야, 사용자가
    /// 둘을 한눈에 구분할 수 있다.
    private var expiredBanner: some View {
        HStack(spacing: 8) {
            Text("토큰이 만료됐습니다. 다시 로그인해 주세요.")
                .font(.callout.bold())
                .foregroundStyle(theme.surfaceBase)
            Spacer()
            Button("로그아웃") { Task { await model.signOut() } }
                .font(.callout)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(theme.danger)
    }

    /// 로그인/매핑 자체는 성공했지만 저장에 실패했을 때(자격증명 또는 워크플로 매핑) 뜬다.
    /// `phase`는 이미 `.ready`이므로 에러가 아니라 경고다 — 지금 세션은 정상 동작하고,
    /// 다음 실행에서 다시 설정해야 할 수 있다는 사실만 알려준다. 그 화면은 이미 사라진
    /// 뒤라 여기 말고는 보여줄 곳이 없다.
    ///
    /// `expiredBanner`와 같은 danger 색을 채움으로 쓰면 "막는 문제"와 "지금은 괜찮지만
    /// 알아둘 것"을 사용자가 구분할 수 없다(M5). 팔레트에 경고 전용 토큰이 없으므로
    /// 색 대신 구조로 가른다: 채움 대신 테두리, 굵기 대신 일반 굵기, 그리고 이미 있던
    /// "⚠" 아이콘.
    private func warningBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Text("⚠ \(message)")
                .font(.callout)
                .foregroundStyle(theme.danger)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(theme.surfaceRaised)
        .overlay(Rectangle().stroke(theme.danger, lineWidth: 1))
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
