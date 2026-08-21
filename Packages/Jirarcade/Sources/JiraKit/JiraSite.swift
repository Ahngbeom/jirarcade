import Foundation

/// 사용자가 입력한 사이트 문자열을 하나의 표준형으로 줄인다.
///
/// 로그인 화면은 자유 입력을 받는다 — 같은 사이트를 `example.atlassian.net`,
/// `https://example.atlassian.net/`, `EXAMPLE.atlassian.net` 어느 쪽으로도 적을 수 있다.
/// 이 셋이 서로 다른 값으로 남으면 사이트를 **비교**하는 쪽(계정 바인딩)이 같은 사이트를
/// 다른 사이트로 착각한다. 그래서 비교하는 쪽과 URL을 만드는 쪽이 같은 규칙을 쓰도록
/// 규칙을 한 곳에 모았다.
///
/// 소문자로 내리는 이유: 호스트명은 대소문자를 구분하지 않는다(RFC 4343). 포트가 붙은
/// `jira.internal:8443` 같은 값도 숫자뿐이라 소문자화에 영향받지 않는다.
public enum JiraSite {
    /// 앞뒤 공백, `https://`/`http://` 접두사, 끝 슬래시를 떼고 소문자로 내린다.
    ///
    /// 유효성은 판단하지 않는다 — 빈 문자열이나 호스트로 쓸 수 없는 값도 그대로 돌려준다.
    /// 그 판정은 URL을 실제로 만드는 쪽(`APITokenAuth.init`)의 몫이다.
    public static func normalize(_ site: String) -> String {
        var text = site.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text.lowercased()
    }
}
