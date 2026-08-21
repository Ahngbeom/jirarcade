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

    /// 사용자가 명시적으로 "채점하지 않음"으로 지정한 상태.
    ///
    /// `statusToStage`에 **없는 것**과 다르다. 그건 "아직 정하지 않았다"이고 폴백 추정이
    /// 적용된다. 여기 있는 것은 "추정도 하지 마라"는 뜻이다 — 실물에서 보류 성격의 상태가
    /// statusCategory가 done이라 완료로 채점되고 마감 보너스까지 받던 사례가 이 구분을
    /// 요구했다. 이 목록이 없으면 잘못 추정된 상태를 **끄는 것**은 불가능하고
    /// 다른 단계로 **바꾸는 것**만 된다.
    public var excludedStatuses: Set<String>

    public init(statusToStage: [String: Stage], excludedStatuses: Set<String> = []) {
        self.statusToStage = statusToStage
        self.excludedStatuses = excludedStatuses
    }

    private enum CodingKeys: String, CodingKey {
        case statusToStage, excludedStatuses
    }

    /// 자동 합성 `Codable`은 누락 키에 기본값을 쓰지 않는다. 제외 목록이 생기기 전에 저장된
    /// `workflow.json`에는 그 키가 없으므로, 직접 디코딩하지 않으면 기존 사용자의 매핑
    /// 파일을 통째로 읽지 못해 마법사가 처음부터 다시 뜬다.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statusToStage = try container.decode([String: Stage].self, forKey: .statusToStage)
        excludedStatuses =
            try container.decodeIfPresent(Set<String>.self, forKey: .excludedStatuses) ?? []
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
    ///
    /// 제외한 상태는 폴백에서 걷어낸다. 그러지 않으면 "사용 안 함"을 골라도 추정값이
    /// 밑에 깔린 채 계속 채점된다 — 정정 사슬의 마지막 고리가 여기서 끊긴다.
    /// 명시적으로 매핑한 상태는 제외 목록에 있어도 그대로 둔다(모순이므로 마법사가
    /// 애초에 둘을 동시에 고르게 하지 않는다).
    public func merging(_ fallbacks: [String: Stage]) -> WorkflowMap {
        let applicable = fallbacks.filter { !excludedStatuses.contains($0.key) }
        return WorkflowMap(
            statusToStage: applicable.merging(statusToStage) { _, mine in mine },
            excludedStatuses: excludedStatuses
        )
    }

    /// 입력에 등장한 상태 중 매핑되지 않은 것을 최초 등장 순서대로, 중복 없이 돌려준다.
    ///
    /// 제외한 상태는 빼고 센다. 그건 "아직 정하지 않았다"가 아니라 사용자가 스스로 끈
    /// 것이므로, 남겨두면 끄는 순간 지울 방법이 없는 경고가 화면에 붙는다.
    public func unmappedStatuses(in statusNames: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in statusNames
        where statusToStage[name] == nil && !excludedStatuses.contains(name) {
            if seen.insert(name).inserted { result.append(name) }
        }
        return result
    }
}
