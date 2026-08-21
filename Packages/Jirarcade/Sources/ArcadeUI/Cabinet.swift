import SwiftUI

/// 아케이드 플로어에 놓이는 캐비닛 하나.
/// 캐비닛은 셸에 데이터를 요청하지 않는다 — 각자 필요한 것을 직접 읽는다.
@MainActor
public protocol Cabinet: Identifiable {
    /// `Identifiable.id`는 nonisolated 요구사항이다. 여기서 그렇게 선언하지 않으면
    /// 준수하는 타입마다 `: @MainActor Cabinet`을 적어야 하고,
    /// 빠뜨리면 "conformance crosses into main actor-isolated code"라는
    /// 원인을 짐작하기 어려운 에러가 난다.
    nonisolated var id: String { get }
    var title: String { get }
    /// 플로어의 캐비닛 화면에 보이는 미리보기 줄.
    var marqueeLines: [String] { get }
    var accentToken: String { get }
    func makeView() -> AnyView
}
