import Foundation

/// 실행 취소 창 안에서 대기 중인 전이 한 건.
///
/// 값 타입이며 스토어에 쓰지 않는다. 롤백은 이 값을 지우는 것이고, Jira에는 아직
/// 아무것도 보내지 않았으므로 되돌릴 것도 없다.
public struct PendingTransition: Sendable, Equatable {
    public let issueKey: String
    public let transitionId: String
    /// 낙관적으로 그릴 상태명. 보드가 이 값으로 단계를 다시 가른다.
    public let toStatusName: String
    /// 요청이 나갈 시각. 카드가 남은 시간을 그린다.
    public let firesAt: Date

    public init(
        issueKey: String, transitionId: String, toStatusName: String, firesAt: Date
    ) {
        self.issueKey = issueKey
        self.transitionId = transitionId
        self.toStatusName = toStatusName
        self.firesAt = firesAt
    }
}
