import Foundation

public struct JiraIssue: Sendable, Equatable {
    public let key: String
    public let summary: String
    public let statusName: String
    public let issueType: String
    public let priority: String?
    public let assigneeAccountId: String?
    public let assigneeName: String?
    public let dueDate: Date?
    public let updated: Date
    /// 이 티켓이 속한 스프린트. 필드 ID를 모르거나 값이 없으면 빈 배열이다.
    public let sprints: [JiraSprint]

    /// 테스트와 ArcadeCore의 ObservedIssue 변환이 쓰는 public 이니셜라이저.
    /// 여기 두는 이유: 이 초기화 구문이 하나라도 원본 struct 선언 안에 있어야
    /// 컴파일러가 (internal 접근 수준의) memberwise 이니셜라이저 합성을 건너뛴다.
    /// extension에 두면 합성된 internal 버전과 시그니처가 겹쳐 재선언 오류가 난다.
    public init(
        key: String, summary: String, statusName: String, issueType: String,
        priority: String?, assigneeAccountId: String?, assigneeName: String?,
        dueDate: Date?, updated: Date, sprints: [JiraSprint] = []
    ) {
        self.key = key
        self.summary = summary
        self.statusName = statusName
        self.issueType = issueType
        self.priority = priority
        self.assigneeAccountId = assigneeAccountId
        self.assigneeName = assigneeName
        self.dueDate = dueDate
        self.updated = updated
        self.sprints = sprints
    }
}

public struct JiraTransition: Sendable, Equatable, Decodable {
    public let id: String
    public let name: String
    public let toStatusName: String

    private enum CodingKeys: String, CodingKey { case id, name, to }
    private struct StatusRef: Decodable { let name: String }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        toStatusName = try container.decode(StatusRef.self, forKey: .to).name
    }

    public static func decodeList(_ data: Data) throws -> [JiraTransition] {
        struct Envelope: Decodable { let transitions: [JiraTransition] }
        return try JSONDecoder().decode(Envelope.self, from: data).transitions
    }
}

public struct JiraUser: Sendable, Equatable, Decodable {
    public let accountId: String
    public let displayName: String
}

public struct DecodingFailure: Sendable, Equatable {
    public let index: Int
    public let reason: String
}

public struct IssuePage: Sendable, Equatable {
    public let issues: [JiraIssue]
    public let failures: [DecodingFailure]
    public let nextPageToken: String?
}

/// 검색 응답을 파싱한다. 개별 이슈의 디코딩 실패가 전체를 무효화하지 않는다.
public enum JiraSearchResponse {
    public static func decode(_ data: Data, sprintFieldID: String? = nil) throws -> IssuePage {
        let decoder = JSONDecoder()
        if let sprintFieldID {
            decoder.userInfo[.sprintFieldID] = sprintFieldID
        }
        let envelope = try decoder.decode(Envelope.self, from: data)

        var issues: [JiraIssue] = []
        var failures: [DecodingFailure] = []
        for (index, element) in envelope.issues.enumerated() {
            if let value = element.value {
                issues.append(value)
            } else {
                failures.append(DecodingFailure(index: index, reason: element.reason ?? "unknown"))
            }
        }
        return IssuePage(issues: issues, failures: failures, nextPageToken: envelope.nextPageToken)
    }

    private struct Envelope: Decodable {
        let issues: [Failable<JiraIssue>]
        let nextPageToken: String?
    }

    /// 요소 하나가 실패해도 배열 전체를 버리지 않게 감싸는 래퍼.
    private struct Failable<T: Decodable>: Decodable {
        let value: T?
        let reason: String?

        init(from decoder: any Decoder) throws {
            do {
                value = try T(from: decoder)
                reason = nil
            } catch {
                value = nil
                reason = String(describing: error)
            }
        }
    }

}

extension JiraSearchResponse {
    fileprivate static func parseTimestamp(_ text: String) -> Date? {
        JiraTimestamp.parse(text)
    }

    fileprivate static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

public extension CodingUserInfoKey {
    /// 스프린트 커스텀 필드의 키. 사이트마다 달라 고정 `CodingKeys`로 잡을 수 없으므로
    /// 디코딩 시점에 주입한다.
    static let sprintFieldID = CodingUserInfoKey(rawValue: "jirarcade.sprintFieldID")!
}

/// 런타임에 정해지는 필드 키를 읽기 위한 CodingKey.
private struct DynamicFieldKey: CodingKey {
    let stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

extension JiraIssue: Decodable {
    private enum CodingKeys: String, CodingKey { case key, fields }
    private enum FieldKeys: String, CodingKey {
        case summary, status, issuetype, priority, assignee, duedate, updated
    }
    private struct Named: Decodable { let name: String }
    private struct Person: Decodable { let accountId: String; let displayName: String }

    public init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        key = try root.decode(String.self, forKey: .key)

        let fields = try root.nestedContainer(keyedBy: FieldKeys.self, forKey: .fields)
        summary = try fields.decode(String.self, forKey: .summary)
        statusName = try fields.decode(Named.self, forKey: .status).name
        issueType = try fields.decode(Named.self, forKey: .issuetype).name
        priority = try fields.decodeIfPresent(Named.self, forKey: .priority)?.name

        let person = try fields.decodeIfPresent(Person.self, forKey: .assignee)
        assigneeAccountId = person?.accountId
        assigneeName = person?.displayName

        if let raw = try fields.decodeIfPresent(String.self, forKey: .duedate) {
            dueDate = JiraSearchResponse.dateOnlyFormatter.date(from: raw)
        } else {
            dueDate = nil
        }

        let rawUpdated = try fields.decode(String.self, forKey: .updated)
        guard let parsed = JiraSearchResponse.parseTimestamp(rawUpdated) else {
            throw DecodingError.dataCorruptedError(
                forKey: .updated, in: fields, debugDescription: "알 수 없는 시각 형식"
            )
        }
        updated = parsed

        // 스프린트는 부가 정보다. 여기서 실패해도 티켓을 잃으면 안 되므로 전부 `try?`로 받는다.
        if let fieldID = decoder.userInfo[.sprintFieldID] as? String,
           let key = DynamicFieldKey(stringValue: fieldID),
           let dynamic = try? root.nestedContainer(keyedBy: DynamicFieldKey.self, forKey: .fields),
           let raw = try? dynamic.decodeIfPresent([FailableSprint].self, forKey: key) {
            sprints = raw.compactMap(\.value)
        } else {
            sprints = []
        }
    }
}
