import Foundation

/// 시트가 여는 티켓 하나. **미러에 들어가지 않는다** — 채점 입력이 아니고
/// 시트가 닫히면 버린다.
public struct JiraIssueDetail: Sendable, Equatable {
    public let key: String
    public let summary: String
    public let description: ADFNode?

    public init(key: String, summary: String, description: ADFNode?) {
        self.key = key
        self.summary = summary
        self.description = description
    }

    public static func decode(_ data: Data) throws -> JiraIssueDetail {
        let raw: Payload
        do {
            raw = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw JiraError.decoding(context: "issueDetail: \(error)")
        }
        return JiraIssueDetail(key: raw.key, summary: raw.fields.summary,
                               description: raw.fields.description)
    }

    private struct Payload: Decodable {
        let key: String
        let fields: Fields
        struct Fields: Decodable {
            let summary: String
            let description: ADFNode?
        }
    }
}

/// 댓글 한 건.
public struct JiraComment: Sendable, Equatable, Identifiable {
    public let id: String
    public let authorName: String
    public let created: Date
    public let body: ADFNode?

    public init(id: String, authorName: String, created: Date, body: ADFNode?) {
        self.id = id
        self.authorName = authorName
        self.created = created
        self.body = body
    }

    /// 이름을 못 읽었을 때 쓸 자리. 댓글을 버리는 것보다 낫다 — 삭제된 계정이나
    /// 앱이 만든 댓글에서 실제로 빠진다.
    public static let unknownAuthor = "알 수 없음"

    /// 한 건이 깨져도 나머지를 살린다. 대화 전체가 사라지면 "지금 무슨 상황인가"를
    /// 판단할 수 없고, 그것이 시트를 여는 이유다.
    public static func decodePage(_ data: Data) throws -> [JiraComment] {
        let page: Page
        do {
            page = try JSONDecoder().decode(Page.self, from: data)
        } catch {
            throw JiraError.decoding(context: "comments: \(error)")
        }
        return page.comments.compactMap { entry in
            guard let id = entry.id, let raw = entry.created,
                  let created = JiraTimestamp.parse(raw) else { return nil }
            return JiraComment(id: id,
                               authorName: entry.author?.displayName ?? unknownAuthor,
                               created: created,
                               body: entry.body)
        }
    }

    private struct Page: Decodable {
        let comments: [Entry]
        struct Entry: Decodable {
            let id: String?
            let created: String?
            let author: Author?
            let body: ADFNode?
            struct Author: Decodable { let displayName: String? }
        }
    }
}
