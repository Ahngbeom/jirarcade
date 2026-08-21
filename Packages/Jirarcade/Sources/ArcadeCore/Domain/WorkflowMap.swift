import Foundation

/// 게임이 이해하는 진행 단계. 조직의 상태명과 1:1이 아니며 WorkflowMap을 통해서만 변환된다.
public enum Stage: String, Codable, Sendable, CaseIterable {
    case backlog, active, review, verify, done

    /// 전진/후퇴 판정에 쓰는 순서값.
    public var order: Int {
        switch self {
        case .backlog: 0
        case .active:  1
        case .review:  2
        case .verify:  3
        case .done:    4
        }
    }
}

public struct WorkflowMap: Codable, Sendable, Equatable {
    public var statusToStage: [String: Stage]

    public init(statusToStage: [String: Stage]) {
        self.statusToStage = statusToStage
    }

    /// 매핑은 사용자가 설정 화면에서 지정한다 — Jira 인스턴스마다 상태명이 다르므로
    /// 특정 조직의 워크플로를 기본값으로 내장하지 않는다.
    ///
    /// 매핑되지 않은 상태는 nil을 돌려준다. 임의의 단계로 폴백하면 점수가 조용히 틀린다.
    public func stage(for statusName: String) -> Stage? {
        statusToStage[statusName]
    }

    /// 폴백 매핑을 밑에 깔고 현재 매핑을 위에 얹은 **실효 맵**을 만든다.
    ///
    /// 사용자가 마법사에서 지정한 매핑이 항상 이긴다 — 폴백은 statusCategory에서
    /// 끌어낸 추정이고, 사용자 선택은 명시적 의도다. 값 타입이므로 원본은 그대로다.
    public func merging(_ fallbacks: [String: Stage]) -> WorkflowMap {
        WorkflowMap(statusToStage: fallbacks.merging(statusToStage) { _, mine in mine })
    }

    /// 입력에 등장한 상태 중 매핑되지 않은 것을 최초 등장 순서대로, 중복 없이 돌려준다.
    public func unmappedStatuses(in statusNames: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in statusNames where statusToStage[name] == nil {
            if seen.insert(name).inserted { result.append(name) }
        }
        return result
    }
}
