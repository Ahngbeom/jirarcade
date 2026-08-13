import Foundation
@testable import JiraKit

/// 테스트 픽스처용 인증. 사이트 리터럴이 잘못되면 즉시 크래시시켜 빨리 드러낸다.
/// `APITokenAuth.init`이 던지게 된 뒤로 파일 스코프 상수를 그냥 만들 수 없어 생긴 헬퍼다.
func fixtureAuth(
    site: String = "example.atlassian.net",
    email: String = "u@e.com",
    token: String = "t"
) -> APITokenAuth {
    guard let auth = try? APITokenAuth(site: site, email: email, token: token) else {
        fatalError("잘못된 사이트 리터럴: \(site)")
    }
    return auth
}
