import Foundation

/// ADF(Atlassian Document Format) 트리의 노드 하나.
///
/// **파싱만 한다.** 무엇을 화면에 어떻게 그릴지는 `ArcadeCore`가 정한다 — 이 타입은
/// 응답에 무엇이 들어 있었는지만 말한다.
///
/// `attrs`를 **전부 문자열로** 눕히는 이유: ADF의 attrs는 종류마다 타입이 제각각이고
/// (`level`은 숫자, `layout`은 문자열) 새 속성이 예고 없이 추가된다. 스칼라를 전부
/// 문자열로 받아 두면 새 속성이 와도 디코딩이 깨지지 않고, 값이 필요해질 때 읽는
/// 쪽에서 해석하면 된다. 객체·배열 값은 여전히 버린다 — 문자열 하나로 눕힐 수 없고,
/// 하나 못 읽는다고 문단 전체를 잃는 것보다 그 속성만 없는 편이 낫다.
public struct ADFNode: Sendable, Equatable {
    public let type: String
    public let text: String?
    public let attrs: [String: String]
    public let content: [ADFNode]
    /// 이 노드에 붙은 서식. 굵게·기울임·링크가 여기 담긴다.
    public let marks: [ADFMark]
    /// 응답에 `marks` 키가 **있었는가**.
    ///
    /// `marks.isEmpty`로 대신할 수 없다: 이 값이 답하는 질문은 "서식이 있었는가"이지
    /// "우리가 서식을 읽어냈는가"가 아니다. 본문 편집을 여는 단계는 화이트리스트로
    /// 판정해야 하는데(모르는 것을 통과시키면 저장할 때 조용히 부순다), 읽지 못한
    /// 서식이 `marks: []`로 보이면 그 판정이 정확히 반대로 뒤집힌다.
    public let hasMarks: Bool

    public init(type: String, text: String? = nil, attrs: [String: String] = [:],
                content: [ADFNode] = [], marks: [ADFMark] = [], hasMarks: Bool? = nil) {
        self.type = type
        self.text = text
        self.attrs = attrs
        self.content = content
        self.marks = marks
        self.hasMarks = hasMarks ?? !marks.isEmpty
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
        content = (try? container.decode([FailableADFNode].self, forKey: .content))?.compactMap(\.value) ?? []
        marks = (try? container.decode([FailableADFMark].self, forKey: .marks))?.compactMap(\.value) ?? []
        hasMarks = container.contains(.marks)
        attrs = (try? container.decode(ScalarAttributes.self, forKey: .attrs))?.values ?? [:]
    }
}

/// 텍스트에 붙은 서식 하나. `type`은 `strong`·`em`·`code`·`link` 같은 ADF의 이름이고,
/// 값이 필요한 서식은 `attrs`에 담긴다(링크는 `href`).
///
/// **파싱만 한다.** 어떤 서식을 그릴지, 그리지 못하는 서식을 어떻게 다룰지는
/// `ArcadeCore`가 정한다 — 이 타입은 응답에 무엇이 있었는지만 말한다.
public struct ADFMark: Sendable, Equatable, Decodable {
    public let type: String
    public let attrs: [String: String]

    public init(type: String, attrs: [String: String] = [:]) {
        self.type = type
        self.attrs = attrs
    }

    private enum CodingKeys: String, CodingKey { case type, attrs }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        attrs = (try? container.decode(ScalarAttributes.self, forKey: .attrs))?.values ?? [:]
    }
}

/// 배열 원소 하나가 실패해도 나머지를 살리는 래퍼.
/// 하나 깨진 노드가 있어도 그 배열 전체를 버리지 않도록 한다.
private struct FailableADFNode: Decodable {
    let value: ADFNode?
    init(from decoder: any Decoder) throws {
        value = try? ADFNode(from: decoder)
    }
}

/// 서식 하나가 깨져도 같은 텍스트의 다른 서식을 살린다. `FailableADFNode`와 같은 이유다 —
/// 링크 하나를 못 읽었다고 굵게까지 잃을 이유가 없다.
private struct FailableADFMark: Decodable {
    let value: ADFMark?
    init(from decoder: any Decoder) throws {
        value = try? ADFMark(from: decoder)
    }
}

/// 어떤 키가 올지 모르는 객체에서 **스칼라 값만** 건져내 전부 문자열로 눕힌다.
///
/// 숫자·불리언까지 받는 이유: 화면에 필요한 값이 전부 문자열이지는 않다. 제목의
/// `level`과 번호 목록의 `order`는 JSON 숫자라, 문자열만 받으면 제목이 몇 단계인지
/// 알 방법이 사라진다. 읽는 쪽이 `Int(...)`로 되돌린다.
///
/// 객체와 배열은 버린다. 문자열 하나로 눕힐 수 없고, 그런 속성을 쓰는 화면이 아직 없다.
private struct ScalarAttributes: Decodable {
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
            } else if let value = try? container.decode(Int.self, forKey: key) {
                found[key.stringValue] = String(value)
            } else if let value = try? container.decode(Double.self, forKey: key) {
                // 정수로 떨어지는 실수는 정수로 적는다 — `level: 3.0`이 "3.0"이 되면
                // 읽는 쪽의 `Int("3.0")`이 nil을 준다.
                found[key.stringValue] = value == value.rounded() && value.magnitude < 1e15
                    ? String(Int(value)) : String(value)
            } else if let value = try? container.decode(Bool.self, forKey: key) {
                found[key.stringValue] = String(value)
            }
        }
        values = found
    }
}
