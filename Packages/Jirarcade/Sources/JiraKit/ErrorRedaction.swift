import Foundation

/// 어떤 에러든 자격증명·응답 본문을 담지 않는 진단용 문자열로 줄인다.
///
/// `JiraError`는 케이스 이름만 남긴다 — `.transitionRejected(reason:)`의 `reason`은
/// Jira 응답의 `errorMessages`를, `.decoding(context:)`의 `context`는 디코더의
/// `debugDescription`을 그대로 담을 수 있어 둘 다 응답 본문 조각(이메일 등)을 실어
/// 나를 수 있다. `JiraError`가 아닌 에러(`DecodingError`, `URLError`, SwiftData 에러 등)는
/// 타입 이름만 남긴다 — 어떤 에러 타입이 이 함수를 거치는지 여기서 전부 알 수 없으므로,
/// 페이로드를 담을 수 있다고 가정하는 쪽이 안전하다.
///
/// 이 함수를 거친 문자열은 로그·에러 문구·UI에 그대로 노출될 수 있는 것으로 취급한다
/// — `ArcadeCore`(디스크에 쓰는 동기화 이력)와 `ArcadeApp`(스케줄러의 `lastFailure`)
/// 양쪽 모두 원본 에러가 아니라 이 함수의 결과만 저장해야 한다.
public func redactedErrorDescription(_ error: any Error) -> String {
    if let jira = error as? JiraError {
        return "JiraError.\(jira.caseName)"
    }
    return String(describing: type(of: error))
}

private extension JiraError {
    var caseName: String {
        switch self {
        case .invalidSite: return "invalidSite"
        case .offline: return "offline"
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .notFound: return "notFound"
        case .rateLimited: return "rateLimited"
        case .transitionRejected: return "transitionRejected"
        case .server: return "server"
        case .decoding: return "decoding"
        }
    }
}
