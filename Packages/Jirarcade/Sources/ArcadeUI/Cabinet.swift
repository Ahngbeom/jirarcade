import SwiftUI

/// 캐비닛을 어떻게 띄우는가.
///
/// 시트는 잠깐 들여다보고 닫는 것이다. 매일 여러 번 여는 화면(퀘스트 보드)에는
/// 맞지 않으므로 같은 창을 채우는 전환을 따로 둔다.
public enum CabinetPresentation: Sendable {
    case sheet
    case fullScreen
}

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
    var presentation: CabinetPresentation { get }
    func makeView() -> AnyView
}

public extension Cabinet {
    /// 기본은 시트다. 전체 화면이 필요한 캐비닛만 스스로 밝힌다.
    var presentation: CabinetPresentation { .sheet }
}
