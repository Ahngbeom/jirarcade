import Foundation

/// 앱이 여는 Atlassian 페이지.
///
/// 로그인 화면과 만료 배너가 **같은 곳**을 가리켜야 하므로 한곳에 둔다. 한쪽만 고치면
/// 사용자가 어느 경로로 왔느냐에 따라 다른 페이지에 도착한다.
enum AtlassianLinks {
    /// API 토큰 발급·취소 페이지.
    ///
    /// Atlassian은 2024-12-15부터 새 토큰을 기본 1년 만료로 발급하고, 2025-03-13부터는
    /// 그 이전에 만든 토큰에도 만료를 적용했다. 즉 모든 사용자가 언젠가 만료를 맞으므로,
    /// 재발급 경로는 로그인 화면뿐 아니라 만료 시점에도 손닿는 곳에 있어야 한다.
    static let apiTokens = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!

    /// 티켓 하나의 Jira 페이지.
    ///
    /// 이 앱이 하지 않는 일(본문 읽기·첨부·이력)이 아직 많고 전부 그쪽에 있다.
    /// 전이가 거부됐을 때도 필요한 정보를 채우러 갈 곳이 여기다.
    ///
    /// `site`는 `JiraSite.normalize`를 거친 호스트여야 한다 — 스킴이 붙어 있으면
    /// `https://https://…`가 된다.
    static func issue(key: String, site: String) -> URL? {
        guard !site.isEmpty, !key.isEmpty else { return nil }
        return URL(string: "https://\(site)/browse/\(key)")
    }
}
