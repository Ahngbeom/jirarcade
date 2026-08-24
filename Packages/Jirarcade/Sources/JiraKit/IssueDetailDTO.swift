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

            private enum CodingKeys: String, CodingKey {
                case summary, description
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                summary = try container.decode(String.self, forKey: .summary)
                description = (try? container.decodeIfPresent(ADFNode.self, forKey: .description)) ?? nil
            }
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
        return page.comments.compactMap(\.value).compactMap { entry in
            guard let id = entry.id, let raw = entry.created,
                  let created = JiraTimestamp.parse(raw) else { return nil }
            return JiraComment(id: id,
                               authorName: entry.author?.displayName ?? unknownAuthor,
                               created: created,
                               body: entry.body)
        }
    }

    private struct Page: Decodable {
        let comments: [FailableEntry]
        struct Entry: Decodable {
            let id: String?
            let created: String?
            let author: Author?
            let body: ADFNode?

            private enum CodingKeys: String, CodingKey {
                case id, created, author, body
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decodeIfPresent(String.self, forKey: .id)
                created = try container.decodeIfPresent(String.self, forKey: .created)
                author = try container.decodeIfPresent(Author.self, forKey: .author)
                body = (try? container.decodeIfPresent(ADFNode.self, forKey: .body)) ?? nil
            }

            struct Author: Decodable { let displayName: String? }
        }

        /// 원소 하나가 깨져도 배열 전체를 버리지 않는다. `decodeIfPresent`는 키가
        /// 없거나 `null`인 것만 견딘다 — 키는 있는데 모양이 안 맞으면(`author`가
        /// `[]`이거나 `id`가 숫자인 경우 등, 앱 액터·익명화된 사용자에서 실제로
        /// 나온다) `Entry.init(from:)`이 그대로 던지고, `[Entry]`로 두면 그 하나가
        /// 컨테이너 전체를 무너뜨린다. `SprintDTO.swift`의 `FailableSprint`,
        /// `ADFNode.swift`의 `FailableADFNode`와 같은 도구다.
        struct FailableEntry: Decodable {
            let value: Entry?
            init(from decoder: Decoder) throws {
                value = try? Entry(from: decoder)
            }
        }
    }
}
