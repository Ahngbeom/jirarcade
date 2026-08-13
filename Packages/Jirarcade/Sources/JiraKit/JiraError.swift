import Foundation

public enum JiraError: Error, Equatable, Sendable {
    /// 사이트 주소로 URL을 만들 수 없다. 입력값 자체는 담지 않는다 —
    /// 자격증명이 섞여 붙여넣기될 수 있고, 이 에러는 로그에 남는다.
    case invalidSite
    case offline
    case unauthorized
    case forbidden(resource: String)
    case notFound(key: String)
    case rateLimited(retryAfter: TimeInterval)
    case transitionRejected(reason: String)
    case server(status: Int)
    case decoding(context: String)
}
