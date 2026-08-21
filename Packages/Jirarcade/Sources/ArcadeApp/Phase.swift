import Foundation

/// 앱이 지금 어느 단계에 있는가. v0.1 스펙 §8.1의 인증 상태 머신에
/// 워크플로 매핑 단계를 더한 형태다.
public enum Phase: Sendable, Equatable {
    /// Keychain에서 자격증명을 찾는 중.
    case launching
    /// 로그인 화면. message가 있으면 직전 시도의 실패 사유를 보여준다.
    case signedOut(message: String?)
    /// 자격증명을 Jira에 확인하는 중.
    case validating
    /// 워크플로 매핑이 필요하다. candidates는 조회에서 실제로 등장한 상태명.
    case mappingWorkflow(candidates: [String])
    /// 정상 동작.
    case ready
    /// 토큰이 만료·회수됐다. 미러는 그대로 보여주고 쓰기만 막는다.
    case expired

    /// 미러(로컬에 쌓인 티켓과 점수)를 화면에 보여도 되는가.
    /// expired가 true인 것이 핵심이다 — 인증 실패로 데이터를 숨기면
    /// 사용자는 재로그인 전까지 아무것도 볼 수 없다.
    public var showsMirror: Bool {
        switch self {
        case .ready, .expired: true
        case .launching, .signedOut, .validating, .mappingWorkflow: false
        }
    }

    /// Jira에 쓰는 동작(전이 실행)을 허용하는가. 계획 2b의 전이 버튼이 이 값을 읽는다.
    public var allowsWriting: Bool {
        self == .ready
    }
}
