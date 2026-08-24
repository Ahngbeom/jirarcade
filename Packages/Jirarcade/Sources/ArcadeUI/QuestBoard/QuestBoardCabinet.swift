import SwiftUI
import ArcadeApp

/// 내 티켓을 정체 시간축 위에 늘어놓는 캐비닛. 이 앱의 본체다.
@MainActor
struct QuestBoardCabinet: Cabinet {
    let model: AppModel

    nonisolated var id: String { "quest-board" }
    var title: String { "QUEST BOARD" }
    var accentToken: String { "accent" }
    var presentation: CabinetPresentation { .fullScreen }

    var marqueeLines: [String] {
        guard !model.issues.isEmpty else {
            return [model.lastSync == nil ? "아직 동기화 전" : "담당한 미완료 티켓 없음"]
        }
        var lines = ["내 티켓 \(model.issues.count)건"]
        if let hygiene = model.hygiene {
            lines.append("위생 \(hygiene.score)")
        }
        return lines
    }

    func makeView() -> AnyView {
        AnyView(QuestBoardView(model: model))
    }
}
