import Foundation

/// 티켓이 속한 스프린트 하나.
///
/// 응답에는 `boardId`·`goal`·`endDate`·`completeDate`도 오지만 담지 않는다 — 실측에서
/// `goal`은 전부 빈 문자열이었고 나머지는 이 계획이 쓰지 않는다.
public struct JiraSprint: Sendable, Equatable {
    public let id: Int
    public let name: String
    /// `closed` / `future` / `active`. 이월 계산은 구분하지 않지만
    /// 나중에 필요할 값이라 담는다.
    public let state: String
    /// 정렬 키. 드물게 없다.
    public let startDate: Date?

    public init(id: Int, name: String, state: String, startDate: Date?) {
        self.id = id
        self.name = name
        self.state = state
        self.startDate = startDate
    }
}

extension JiraSprint: Decodable {
    private enum CodingKeys: String, CodingKey { case id, name, state, startDate }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        // `name`이 없는 원소를 필수 실패로 드롭하면 `SprintHistory.summarize`가 세는
        // `ordered.count`가 그만큼 줄어든다 — `name`은 표시에만 쓰이는 값이 아니라
        // 이월 횟수 자체의 입력이다(카운트는 이름이 아니라 원소 존재 여부로 매긴다).
        // `state`와 같은 이유로 필수 해제한다 — 아래 참고.
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        // 값을 읽는 곳이 지금은 없지만(위 doc-comment 참고) 그렇다고 없는 것과 같은
        // 취급을 하면 안 된다: 필수로 두면 `state`가 빠진 원소 하나 때문에 스프린트
        // 전체가 `FailableSprint`에서 조용히 드롭되고, 이월 횟수가 실제보다 낮게 뜬다 —
        // "↻ 스프린트 5회"가 사실은 6회일 수 있다는 뜻이다. 아무것도 안 보여주는 것보다
        // 나쁘다: 숫자가 있으니 사용자는 그것이 정확하다고 믿는다.
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        if let raw = try container.decodeIfPresent(String.self, forKey: .startDate) {
            startDate = JiraSprint.parseTimestamp(raw)
        } else {
            startDate = nil
        }
    }

    /// 원소 하나가 깨져도 배열 전체를 버리지 않는다.
    /// `JiraSearchResponse`가 이슈 단위로 이미 쓰는 방식이다 — 스프린트 하나 때문에
    /// 그 티켓의 이월 정보를 통째로 잃으면 안 된다.
    public static func decodeList(_ data: Data) throws -> [JiraSprint] {
        try JSONDecoder().decode([FailableSprint].self, from: data).compactMap(\.value)
    }

    static func parseTimestamp(_ text: String) -> Date? {
        JiraTimestamp.parse(text)
    }
}

/// `/rest/api/3/field` 응답에서 스프린트 필드를 찾는다.
public enum JiraFieldCatalog {
    /// Greenhopper 시절부터 유지돼 온 스프린트 필드의 스키마 식별자.
    /// **로케일과 무관하다** — 이것으로 찾는 이유가 그것이다.
    static let sprintSchema = "com.pyxis.greenhopper.jira:gh-sprint"

    /// 스프린트 필드의 커스텀 필드 ID. 없으면 nil.
    ///
    /// **이름으로 찾지 않는다.** 실측 사이트의 필드 이름은 `"Sprint"`가 아니라 `"스프린트"`였다.
    /// 이름은 사이트 로케일을 따르므로, 이름 비교는 영어 사이트에서만 동작하고 다른 곳에서는
    /// 아무것도 찾지 못한 채 조용히 지나간다.
    public static func sprintFieldID(in data: Data) throws -> String? {
        struct Entry: Decodable {
            let id: String
            let schema: Schema?
            struct Schema: Decodable { let custom: String? }
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return entries.first { $0.schema?.custom == sprintSchema }?.id
    }
}

/// 배열 원소 하나가 실패해도 나머지를 살리는 래퍼.
/// `JiraSearchResponse`가 이슈 단위로 쓰는 것과 같은 도구이며, 여기서는 스프린트 원소에 쓴다.
struct FailableSprint: Decodable {
    let value: JiraSprint?
    init(from decoder: any Decoder) throws {
        value = try? JiraSprint(from: decoder)
    }
}
