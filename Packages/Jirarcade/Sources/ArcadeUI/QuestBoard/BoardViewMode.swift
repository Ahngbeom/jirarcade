import SwiftUI

/// 퀘스트 보드가 같은 데이터를 보여주는 두 방식.
///
/// 세션 동안만 유지하고 저장하지 않는다 — 레인이 일하는 화면이고 궤도가 보는 화면이므로,
/// 앱을 다시 열었을 때 돌아갈 자리는 레인이다.
enum BoardViewMode: String, CaseIterable, Identifiable {
    case lanes, orbit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lanes: "≣ 레인"
        case .orbit: "◎ 궤도"
        }
    }
}
