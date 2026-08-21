import Foundation
import JiraKit

/// 상태 하나를 단계로 해석한 결과. 어떤 경로로 결정됐는지 구분해 UI가 정확도를 표시할 수 있다.
public enum StageResolution: Sendable, Equatable {
    /// ① 현재 워크플로 매핑에 있었다. 정확하다.
    case mapped(Stage)
    /// ② statusCategory로 떨어뜨렸다. 방향은 맞지만 세분화가 없다.
    case fallback(Stage)
    /// ③ 어느 쪽에도 없다. XP 0이며 매핑 마법사 후보가 된다.
    case unmapped(String)

    /// 채점에 쓸 단계. 미매핑이면 nil이다.
    public var stage: Stage? {
        switch self {
        case .mapped(let s), .fallback(let s): s
        case .unmapped: nil
        }
    }
}

/// 3단 폴백으로 상태를 단계에 매핑한다(스펙 §5).
///
/// 과거 워크플로가 개편되면 changelog에는 현재 매핑에 없는 상태명이 대량 등장한다.
/// 그걸 전부 0점 처리하면 소급의 상당 부분이 사라지므로, Jira가 모든 상태에 붙이는
/// statusCategory(new/indeterminate/done)로 떨어뜨린다.
public final class StatusCatalog: @unchecked Sendable {
    private let workflow: WorkflowMap
    private let byId: [String: JiraStatusCatalogEntry]
    private let lock = NSLock()
    private var collected: Set<String> = []

    public init(workflow: WorkflowMap, entries: [JiraStatusCatalogEntry]) {
        self.workflow = workflow
        self.byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 폴백·미매핑으로 처리된 상태명. 백필이 끝나면 매핑 마법사 후보가 된다.
    public var unmappedNames: Set<String> {
        lock.withLock { collected }
    }

    public func stage(forId id: String?, name: String?) -> StageResolution {
        let label = name ?? id ?? ""

        // ① 현재 매핑
        if let name, let mapped = workflow.stage(for: name) {
            return .mapped(mapped)
        }

        // ② statusCategory 폴백. 이름은 바뀔 수 있으므로 ID로 찾는다.
        if let id, let entry = byId[id], let stage = Self.stage(forCategory: entry.categoryKey) {
            collect(label)
            return .fallback(stage)
        }

        // ③ 미매핑
        collect(label)
        return .unmapped(label)
    }

    /// 빈 라벨은 수집하지 않는다 — 마법사에 이름 없는 항목이 뜨면 사용자가
    /// 무엇을 매핑하는지 알 수 없다. 해석 결과(.unmapped(""))는 그대로 돌려주되
    /// 후보 목록에만 넣지 않는다.
    private func collect(_ label: String) {
        guard !label.isEmpty else { return }
        lock.withLock { _ = collected.insert(label) }
    }

    private static func stage(forCategory key: String) -> Stage? {
        switch key {
        case "new": .backlog
        case "indeterminate": .active
        case "done": .done
        default: nil
        }
    }
}
