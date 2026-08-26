import SwiftUI

/// 퀘스트 보드가 같은 데이터를 보여주는 두 방식.
///
/// 세션 동안만 유지하고 저장하지 않는다 — 앱을 다시 열었을 때 돌아갈 자리는 늘 같아야
/// 하고, 그 자리가 `default`다.
enum BoardViewMode: String, CaseIterable, Identifiable {
    case lanes, orbit

    /// 보드를 열면 궤도가 먼저 뜬다.
    ///
    /// 예전 기본은 레인이었다. 레인이 일하는 화면이라는 판단은 지금도 맞지만, 보드를
    /// 여는 이유가 "무엇부터 손댈지 고르는 것"이라면 먼저 나와야 하는 것은 목록이
    /// 아니라 분포다 — 어느 단계에 얼마나 밀려 있고 무엇이 얼마나 멀리 떠 있는지는
    /// 궤도가 한눈에 답하고, 레인은 그것을 이미 아는 사람이 실행하러 가는 곳이다.
    /// 행성을 눌러 티켓을 읽을 수 있게 되면서 궤도만으로 판단을 끝낼 수 있게 된 것도
    /// 이 순서를 바꾼 이유다.
    static let `default` = BoardViewMode.orbit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lanes: "≣ 레인"
        case .orbit: "◎ 궤도"
        }
    }
}
