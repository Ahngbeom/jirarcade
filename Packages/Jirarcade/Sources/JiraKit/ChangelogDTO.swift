import Foundation

/// changelog history 안의 개별 변경 항목. 어떤 필드가 무엇에서 무엇으로 바뀌었는지.
public struct JiraChangelogItem: Sendable, Equatable {
    public let field: String
    public let fromId: String?
    public let fromString: String?
    public let toId: String?
    public let toString: String?
}

/// 한 번의 변경(한 사람이 한 시각에 저장한 묶음). 여러 필드가 함께 바뀔 수 있다.
public struct JiraChangelogHistory: Sendable, Equatable {
    public let id: String
    public let createdAt: Date
    public let authorAccountId: String?
    public let items: [JiraChangelogItem]
}

public struct JiraChangelogPage: Sendable, Equatable {
    public let startAt: Int
    public let maxResults: Int
    public let total: Int
    public let histories: [JiraChangelogHistory]

    /// 서버가 잘라 보냈는지. true면 `/issue/{key}/changelog`로 보충해야 한다.
    public var isTruncated: Bool { total > histories.count }
}

public struct JiraIssueWithChangelog: Sendable, Equatable {
    public let key: String
    public let createdAt: Date
    public let dueDate: Date?
    public let changelog: JiraChangelogPage
}

public enum JiraChangelogResponse {
    public static func decodeSearch(
        _ data: Data
    ) throws -> (issues: [JiraIssueWithChangelog], nextPageToken: String?) {
        let envelope = try JSONDecoder().decode(SearchEnvelope.self, from: data)
        return (try envelope.issues.map { try $0.model() }, envelope.nextPageToken)
    }

    public static func decodeIssueChangelog(_ data: Data) throws -> JiraChangelogPage {
        let raw = try JSONDecoder().decode(StandaloneEnvelope.self, from: data)
        return JiraChangelogPage(
            startAt: raw.startAt, maxResults: raw.maxResults, total: raw.total,
            histories: try raw.values.map { try $0.model() }
        )
    }

    // MARK: - 내부 디코딩 표현

    private struct SearchEnvelope: Decodable {
        let issues: [RawIssue]
        let nextPageToken: String?
    }

    private struct StandaloneEnvelope: Decodable {
        let startAt: Int
        let maxResults: Int
        let total: Int
        let values: [RawHistory]
    }

    private struct RawIssue: Decodable {
        let key: String
        let fields: Fields
        let changelog: RawChangelog

        struct Fields: Decodable {
            let created: String
            let duedate: String?
        }

        func model() throws -> JiraIssueWithChangelog {
            guard let createdAt = JiraChangelogResponse.timestamp(fields.created) else {
                throw JiraError.decoding(context: "issue \(key): created=\(fields.created)")
            }
            return JiraIssueWithChangelog(
                key: key,
                createdAt: createdAt,
                dueDate: fields.duedate.flatMap(JiraChangelogResponse.dateOnly),
                changelog: try changelog.model()
            )
        }
    }

    private struct RawChangelog: Decodable {
        let startAt: Int
        let maxResults: Int
        let total: Int
        let histories: [RawHistory]

        func model() throws -> JiraChangelogPage {
            JiraChangelogPage(startAt: startAt, maxResults: maxResults, total: total,
                              histories: try histories.map { try $0.model() })
        }
    }

    private struct RawHistory: Decodable {
        let id: String
        let created: String
        let author: Author?
        let items: [RawItem]

        struct Author: Decodable { let accountId: String? }

        func model() throws -> JiraChangelogHistory {
            guard let createdAt = JiraChangelogResponse.timestamp(created) else {
                throw JiraError.decoding(context: "history \(id): created=\(created)")
            }
            return JiraChangelogHistory(
                id: id,
                createdAt: createdAt,
                authorAccountId: author?.accountId,
                items: items.map(\.model)
            )
        }
    }

    private struct RawItem: Decodable {
        let field: String
        let from: String?
        let fromString: String?
        let to: String?
        let toString: String?

        var model: JiraChangelogItem {
            JiraChangelogItem(field: field, fromId: from, fromString: fromString,
                              toId: to, toString: toString)
        }
    }

    // MARK: - 시각 파싱

    /// Jira는 `2023-02-28T10:15:06.939+0900` 형태를 보낸다. 소수점이 없는 변형도
    /// 받아들인다 — 하나만 지원하면 전량 파싱 실패로 이어질 수 있다.
    static func timestamp(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    static func dateOnly(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }
}

/// `/rest/api/3/status`의 항목. 워크플로에서 빠진 과거 상태도 여기 남아 있어,
/// 매핑되지 않은 상태를 statusCategory로 폴백할 수 있다(스펙 §5).
public struct JiraStatusCatalogEntry: Sendable, Equatable, Decodable {
    public let id: String
    public let name: String
    /// `new` / `indeterminate` / `done`. Jira의 3분류 키다.
    public let categoryKey: String

    private enum CodingKeys: String, CodingKey { case id, name, statusCategory }
    private struct Category: Decodable { let key: String }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        categoryKey = try container.decode(Category.self, forKey: .statusCategory).key
    }

    public init(id: String, name: String, categoryKey: String) {
        self.id = id
        self.name = name
        self.categoryKey = categoryKey
    }
}
