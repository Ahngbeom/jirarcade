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

    /// 테스트와 ArcadeCore의 ObservedIssue 변환이 쓰는 public 이니셜라이저.
    /// 여기 두는 이유: 이 초기화 구문이 하나라도 원본 struct 선언 안에 있어야
    /// 컴파일러가 (internal 접근 수준의) memberwise 이니셜라이저 합성을 건너뛴다.
    /// extension에 두면 합성된 internal 버전과 시그니처가 겹쳐 재선언 오류가 난다.
    public init(
        key: String, summary: String, statusName: String, issueType: String,
        priority: String?, assigneeAccountId: String?, assigneeName: String?,
        dueDate: Date?, updated: Date
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
    public static func decode(_ data: Data) throws -> IssuePage {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)

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
    // ISO8601DateFormatter/DateFormatter는 Sendable을 준수하지 않지만, 설정을 마친 뒤
    // 값을 바꾸지 않고 포맷팅에만 쓰므로(Apple 문서상 이 두 포매터는 스레드 세이프) 안전하다.
    /// `.withFractionalSeconds`가 켜진 포매터는 소수점이 **없으면 nil을 돌려준다**.
    /// Jira Cloud는 보통 `.000`을 붙이지만 배포·프록시에 따라 빠질 수 있고, 그때 이슈가
    /// 통째로 디코딩 실패해 전량 손실로 이어진다. 두 포매터를 순서대로 시도한다.
    fileprivate nonisolated(unsafe) static let timestampFormatters: [ISO8601DateFormatter] = {
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

    fileprivate static func parseTimestamp(_ text: String) -> Date? {
        for formatter in timestampFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
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
    }
}
