import Foundation

/// ADF(Atlassian Document Format) 트리의 노드 하나.
///
/// **파싱만 한다.** 무엇을 화면에 어떻게 그릴지는 `ArcadeCore`가 정한다 — 이 타입은
/// 응답에 무엇이 들어 있었는지만 말한다.
///
/// `attrs`에서 문자열 값만 남기는 이유: ADF의 attrs는 종류마다 타입이 제각각이고
/// (`width`는 숫자, `layout`은 문자열) 새 속성이 예고 없이 추가된다. 화면에 필요한
/// 값(`text`·`shortName`·`url`)은 전부 문자열이므로, 나머지를 버리는 편이
/// 하나라도 못 읽으면 문단 전체를 잃는 것보다 낫다.
public struct ADFNode: Sendable, Equatable {
    public let type: String
    public let text: String?
    public let attrs: [String: String]
    public let content: [ADFNode]
    /// 굵게·기울임·링크 같은 서식이 붙어 있는지. 값은 담지 않는다 — 평문으로 그리는
    /// 동안에는 쓰지 않고, 본문 편집을 여는 단계가 "손실 없이 왕복 가능한가"를
    /// 판단할 때만 필요하다.
    public let hasMarks: Bool

    public init(type: String, text: String? = nil, attrs: [String: String] = [:],
                content: [ADFNode] = [], hasMarks: Bool = false) {
        self.type = type
        self.text = text
        self.attrs = attrs
        self.content = content
        self.hasMarks = hasMarks
    }

    public static func decode(_ data: Data) throws -> ADFNode {
        try JSONDecoder().decode(ADFNode.self, from: data)
    }
}

extension ADFNode: Decodable {
    private enum CodingKeys: String, CodingKey { case type, text, attrs, content, marks }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        content = (try? container.decode([ADFNode].self, forKey: .content)) ?? []
        hasMarks = container.contains(.marks)
        attrs = (try? container.decode(StringAttributes.self, forKey: .attrs))?.values ?? [:]
    }
}

/// 어떤 키가 올지 모르는 객체에서 **문자열 값만** 건져낸다.
private struct StringAttributes: Decodable {
    let values: [String: String]

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var found: [String: String] = [:]
        for key in container.allKeys {
            if let value = try? container.decode(String.self, forKey: key) {
                found[key.stringValue] = value
            }
        }
        values = found
    }
}
