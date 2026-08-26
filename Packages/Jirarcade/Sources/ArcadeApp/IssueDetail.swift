import Foundation
import ArcadeCore

/// 시트가 그릴 티켓 하나. **미러에 들어가지 않는다** — 채점 입력이 아니고,
/// 넣으면 마이그레이션과 용량이 따라오며 `DiffEngine`이 본문 변화를 이벤트로
/// 오해할 수 있다.
public struct IssueDetailView: Sendable, Equatable {
    public let key: String
    public let summary: String
    /// ADF를 화면 구조로 옮긴 결과. 모르는 서식은 자리표시자 블록으로 남아 있다.
    public let description: RichDocument
    public let comments: [CommentView]
}

public struct CommentView: Sendable, Equatable, Identifiable {
    public let id: String
    public let authorName: String
    public let created: Date
    public let body: RichDocument
}

public enum IssueDetailState: Sendable, Equatable {
    case idle
    case loading(issueKey: String)
    case loaded(IssueDetailView)
    /// 화면에 그대로 그릴 문구. **Jira가 준 사유가 들어 있지 않다.**
    case failed(String)
}
