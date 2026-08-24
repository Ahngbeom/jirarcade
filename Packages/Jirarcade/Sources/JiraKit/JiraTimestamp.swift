import Foundation

/// Jira가 주는 타임스탬프 문자열을 `Date`로 옮긴다.
///
/// `DTO.swift`가 `fileprivate`로 갖고 있던 것을 옮겼다. 상세·댓글 응답도 같은 형식을
/// 쓰는데 다른 파일에서는 닿지 않아, 파서가 둘로 갈라질 자리였다.
public enum JiraTimestamp {
    // ISO8601DateFormatter는 Sendable을 준수하지 않지만, 설정을 마친 뒤 값을 바꾸지 않고
    // 파싱에만 쓰므로 안전하다(Apple 문서상 이 포매터는 스레드 세이프).
    //
    // `.withFractionalSeconds`가 켜진 포매터는 소수점이 **없으면 nil을 돌려준다**.
    // Jira Cloud는 보통 `.000`을 붙이지만 배포·프록시에 따라 빠질 수 있고, 그때 값이
    // 통째로 파싱 실패한다. 두 포매터를 순서대로 시도한다.
    nonisolated(unsafe) private static let formatters: [ISO8601DateFormatter] = {
        let variants: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ]
        return variants.map { options in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            return formatter
        }
    }()

    public static func parse(_ text: String) -> Date? {
        for formatter in formatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
