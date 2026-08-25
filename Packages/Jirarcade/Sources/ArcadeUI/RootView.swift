import SwiftUI
import ArcadeApp
import ArcadeCore

public struct RootView: View {
    @Environment(\.colorScheme) private var colorScheme
    private let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        // 밀도는 **창 폭**에서 나온다. GeometryReader를 여기 한 번만 두고 환경으로
        // 내려보내는 이유: 화면마다 각자 재면 시트처럼 자기 창을 갖는 것과 본문이
        // 서로 다른 밀도를 쓰게 되고, 같은 라벨이 화면마다 다른 크기로 보인다.
        GeometryReader { geometry in
            RootContent(model: model)
                .arcadeMetrics(forWidth: geometry.size.width)
        }
        // 최소 크기는 GeometryReader **바깥**에 둔다. GeometryReader는 주어진 공간을
        // 그대로 채우기만 하므로 안쪽에 두면 창의 최소 크기로 전달되지 않는다
        // (`.windowResizability(.contentMinSize)`가 읽는 값이 이것이다).
        .frame(minWidth: LayoutTokens.minimumWindow.width,
               minHeight: LayoutTokens.minimumWindow.height)
        .arcadeTheme(model.appearancePreference, systemIsDark: colorScheme == .dark)
    }
}

private struct RootContent: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
    let model: AppModel

    @State private var showingTokenRenewal = false

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
            // 전부 참이어야 한다: (a) `phase = .expired`를 세팅하는 곳은 (이제 여러
            // 군데다 — AppModel.swift에서 `phase = .expired`를 찾아 개수를 세어 볼 것)
            // 전부 인증 실패(401 등) 응답에 대한 반응이고, (b) 그중 `client`를 nil로
            // 남기는 쪽은 `validate(persistOnSuccess: false)` 한 곳뿐이며 그 경로는
            // performSync()를 통해 `.ready`로 회복하는 일이 없고(guard let client에서
            // 막힘), 나머지는 전부 client를 채운 채로 `.expired`가 된다(그래서
            // performSync()가 재인증 없이 회복시킬 수 있다), (c) startSyncing()을 부르는
            // 곳은 이 한 곳뿐이다. 셋 중 하나라도 깨지면 — client를 채운 채로
            // `.signedOut` 같은 다른 phase로 새지거나, startSyncing()을 부르는 곳이
            // 늘거나, (b)의 그 한 곳이 client를 세팅하게 되면 — 이 조건은 조용히
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
        HStack(spacing: metrics.sectionGap) {
            Text("토큰이 만료됐습니다. 새 토큰을 발급받아 갱신해 주세요.")
                .arcadeType(.prose, .m, weight: .bold)
                .foregroundStyle(theme.surfaceBase)
            Spacer()
            // 재발급 경로를 여기 두는 이유: 이 링크는 로그인 화면에도 있지만, 거기 닿으려면
            // 먼저 로그아웃해야 한다. 만료는 사용자가 고를 수 있는 상황이 아니라 반드시
            // 거쳐야 하는 길목이므로, 그 길목에서 바로 갈 수 있어야 한 단계가 준다.
            // 색은 accent가 아니라 surfaceBase다 — 배너가 danger로 채워져 있어
            // accent를 얹으면 대비가 무너진다.
            Link("새 토큰 발급", destination: AtlassianLinks.apiTokens)
                .arcadeType(.prose, .m)
                .foregroundStyle(theme.surfaceBase)
            // 주 동작. 예전에는 여기 있는 유일한 출구가 로그아웃이었는데, 로그아웃은
            // 자격증명 항목을 통째로 지워(`CredentialStore.clear`) 사이트 주소와 이메일까지
            // 함께 날린다 — 바뀐 것은 토큰 하나뿐인데 셋을 다시 입력하게 되는 셈이었다.
            Button("토큰 갱신") { showingTokenRenewal = true }
                .arcadeType(.prose, .m, weight: .bold)
                // 기억한 연결이 없으면 토큰만으로는 어디에 붙을지 알 수 없다.
                // 그 경우 남는 길은 로그아웃 뒤 처음부터 입력하는 것뿐이다.
                .disabled(model.signInHint == nil)
            Button("로그아웃") { Task { await model.signOut() } }
                .arcadeType(.prose, .m)
        }
        .padding(.horizontal, metrics.gutter)
        .padding(.vertical, metrics.rowGap)
        .background(theme.danger)
        // 시트를 배너에 붙인다 — 이 배너가 여는 유일한 곳이고, 아래 `content`에 붙이면
        // 화면 전환(`phase` 변화)과 시트 표시가 같은 뷰에 얽힌다.
        .sheet(isPresented: $showingTokenRenewal) {
            if let hint = model.signInHint {
                TokenRenewalView(
                    model: model,
                    hint: hint,
                    onRenewed: { showingTokenRenewal = false },
                    onCancel: { showingTokenRenewal = false }
                )
                .frame(minWidth: metrics.size(.sheetMinWidth))
                // 시트는 환경을 물려받지 않는다 — 테마와 밀도를 함께 다시 주입한다.
                .environment(\.arcadeTheme, theme)
                .environment(\.arcadeMetrics, metrics)
            }
        }
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
        HStack(spacing: metrics.tightGap) {
            Text("⚠ \(message)")
                .arcadeType(.prose, .m)
                .foregroundStyle(theme.danger)
            Spacer()
        }
        .padding(.horizontal, metrics.gutter)
        .padding(.vertical, metrics.rowGap)
        .background(theme.surfaceRaised)
        .overlay(Rectangle().stroke(theme.danger, lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .launching:
            // 남은 공간을 전부 차지해야 가운데에 선다. 프레임을 주지 않으면 자기
            // 크기만큼만 잡아 배너 아래 좌측 상단에 붙는다 — 다른 단계의 화면들은
            // 모두 스스로 `maxWidth/maxHeight: .infinity`를 갖고 있어 이 분기만 어긋났다.
            ProgressView()
                .tint(theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
