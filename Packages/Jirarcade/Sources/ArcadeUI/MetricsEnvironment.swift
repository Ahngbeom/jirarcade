import SwiftUI
import ArcadeCore

private struct ArcadeMetricsKey: EnvironmentKey {
    /// 주입되지 않은 곳(미리보기·시트가 환경을 놓친 경우)에서도 가장 좁은 밀도로
    /// 동작한다. 큰 치수가 기본값이면 그런 자리에서 내용이 잘린다.
    static let defaultValue = ArcadeMetrics(density: .compact)
}

public extension EnvironmentValues {
    var arcadeMetrics: ArcadeMetrics {
        get { self[ArcadeMetricsKey.self] }
        set { self[ArcadeMetricsKey.self] = newValue }
    }
}

public extension View {
    /// 창 폭에서 밀도를 정해 주입한다.
    func arcadeMetrics(forWidth width: Double) -> some View {
        environment(\.arcadeMetrics, .make(forWidth: width))
    }
}
