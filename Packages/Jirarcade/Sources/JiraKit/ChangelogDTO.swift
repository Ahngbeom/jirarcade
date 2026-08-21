import Foundation

/// changelog history 안의 개별 변경 항목. 어떤 필드가 무엇에서 무엇으로 바뀌었는지.
public struct JiraChangelogItem: Sendable, Equatable {
    public let field: String
    public let fromId: String?
    public let fromString: String?
    public let toId: String?
    public let toString: String?

    public init(field: String, fromId: String?, fromString: String?,
                toId: String?, toString: String?) {
        self.field = field
        self.fromId = fromId
        self.fromString = fromString
        self.toId = toId
        self.toString = toString
    }
}

/// 한 번의 변경(한 사람이 한 시각에 저장한 묶음). 여러 필드가 함께 바뀔 수 있다.
public struct JiraChangelogHistory: Sendable, Equatable {
    public let id: String
    public let createdAt: Date
    public let authorAccountId: String?
    public let items: [JiraChangelogItem]

    public init(id: String, createdAt: Date, authorAccountId: String?,
                items: [JiraChangelogItem]) {
        self.id = id
        self.createdAt = createdAt
        self.authorAccountId = authorAccountId
        self.items = items
    }
}

public struct JiraChangelogPage: Sendable, Equatable {
    public let startAt: Int
    public let maxResults: Int
    public let total: Int
    public let histories: [JiraChangelogHistory]

    public init(startAt: Int, maxResults: Int, total: Int,
                histories: [JiraChangelogHistory]) {
        self.startAt = startAt
        self.maxResults = maxResults
        self.total = total
        self.histories = histories
    }

    /// 서버가 잘라 보냈는지. true면 `/issue/{key}/changelog`로 보충해야 한다.
    public var isTruncated: Bool { total > histories.count }
}

public struct JiraIssueWithChangelog: Sendable, Equatable {
    public let key: String
    public let createdAt: Date
    public let dueDate: Date?
    public let changelog: JiraChangelogPage

    public init(key: String, createdAt: Date, dueDate: Date?,
                changelog: JiraChangelogPage) {
        self.key = key
        self.createdAt = createdAt
        self.dueDate = dueDate
        self.changelog = changelog
    }
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

    /// 해석 가능한 항목만 살려서 목록을 만든다.
    ///
    /// 관대하게 받는 이유: 이 카탈로그는 매핑에 없는 과거 상태를 statusCategory로 되살리는
    /// **보조 정보**다(스펙 §5의 폴백 ②). `StatusDetails`에는 required 필드가 하나도 없어서
    /// 항목 하나가 `id`/`name`/`statusCategory` 중 무엇이든 빠뜨리면 배열 전체 디코드가
    /// 실패하고, 그러면 폴백 ②가 통째로 죽어 과거 상태가 전부 0점 처리된다. 항목 999개를
    /// 1개 때문에 잃는 것보다 999개를 쓰는 편이 낫다.
    ///
    /// 단, 최상위가 배열이 아닌 등 응답 자체가 어긋나면 그대로 던진다 — 그건 "일부 항목이
    /// 낯설다"가 아니라 엔드포인트를 잘못 불렀다는 뜻이다.
    static func decodeList(_ data: Data) throws -> [JiraStatusCatalogEntry] {
        try JSONDecoder().decode([Lenient].self, from: data).compactMap(\.entry)
    }

    /// 원소 하나의 디코딩 실패를 그 원소에 가둬 두는 래퍼. 래퍼 자체는 항상 성공하므로
    /// unkeyed container가 다음 원소로 정상적으로 넘어간다.
    private struct Lenient: Decodable {
        let entry: JiraStatusCatalogEntry?

        init(from decoder: any Decoder) throws {
            entry = try? JiraStatusCatalogEntry(from: decoder)
        }
    }
}
