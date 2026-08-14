import SwiftUI

/// 아케이드 플로어에 놓이는 캐비닛 하나.
/// 캐비닛은 셸에 데이터를 요청하지 않는다 — 각자 필요한 것을 직접 읽는다.
@MainActor
public protocol Cabinet: Identifiable {
    var id: String { get }
    var title: String { get }
    /// 플로어의 캐비닛 화면에 보이는 미리보기 줄.
    var marqueeLines: [String] { get }
    var accentToken: String { get }
    func makeView() -> AnyView
}
