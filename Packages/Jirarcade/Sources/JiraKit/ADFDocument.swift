import Foundation

/// 우리가 만들어 Jira로 보내는 ADF 문서.
///
/// 읽기용 `ADFNode`와 나눈 이유: 보내는 문서는 우리가 처음부터 짓기 때문에 모양이
/// 좁고 확정적이다. 읽기 타입을 그대로 쓰면 보낼 수 없는 조합(표·첨부)까지
/// 표현할 수 있게 되어, 만들 수 없는 것을 만들지 않는다는 보장이 사라진다.
public struct ADFDocument: Encodable, Sendable, Equatable {
    public let version: Int
    public let type: String
    public let content: [Block]

    public init(content: [Block]) {
        self.version = 1
        self.type = "doc"
        self.content = content
    }

    public struct Block: Encodable, Sendable, Equatable {
        public let type: String
        public let content: [Inline]

        public init(content: [Inline]) {
            self.type = "paragraph"
            self.content = content
        }
    }

    public struct Inline: Encodable, Sendable, Equatable {
        /// `"text"` 또는 `"hardBreak"`.
        public let type: String
        /// `hardBreak`에는 없다.
        public let text: String?

        public init(type: String, text: String?) {
            self.type = type
            self.text = text
        }
    }
}
