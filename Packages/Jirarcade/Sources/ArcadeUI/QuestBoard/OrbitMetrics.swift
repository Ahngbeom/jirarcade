import SwiftUI
import ArcadeCore

/// 논리 좌표(1.0 = 궤도 최대 반경)를 pt로 옮기는 곱셈만 모은 값 타입.
///
/// 판단은 `OrbitLayout`이 이미 끝냈다 — 여기에는 등급 판정도 정렬도 겹침 해소도 없다.
/// `BoardMetrics`가 같은 이유로 같은 모양이다.
struct OrbitMetrics {
    let viewport: CGSize
    /// 논리 1.0이 몇 pt인가.
    let scale: Double
    let pan: CGSize
    /// 성계 전체가 들어가는 논리 반지름. `OrbitSnapshot.extent`에서 온다.
    let extent: Double

    /// 성계 넷이 모두 들어오는 배율.
    ///
    /// `extent`는 스냅샷이 알려준다 — **상수로 둘 수 없다.** 성계의 크기가 그 `Stage`에
    /// 접힌 상태 수에 따라 달라지기 때문이다(`OrbitLayout.statusOrbit(count:)`). 상태가
    /// 여덟인 조직과 둘인 조직은 논리 좌표에서 성계 크기가 두 배 넘게 차이 난다.
    ///
    /// 지름(`extent * 2`)에 가장자리 여백 2.0을 더한 값으로 나눈다. 떠돌이 고리는
    /// `extent`에 들어 있지 않다 — 미매핑 상태가 없는 것이 정상이고, 있을 때를 기준으로
    /// 배율을 잡으면 평소에 성계가 화면 한가운데 작게 뭉친다.
    static func fitScale(viewport: CGSize, extent: Double) -> Double {
        min(viewport.width, viewport.height) / max(extent * 2 + 2.0, 1)
    }

    static func minScale(viewport: CGSize, extent: Double) -> Double {
        fitScale(viewport: viewport, extent: extent) * 0.6
    }

    static func maxScale(viewport: CGSize, extent: Double) -> Double {
        fitScale(viewport: viewport, extent: extent) * 6
    }

    /// 태양이 상태별로 다 갈라지는 배율.
    private static func spreadScale(viewport: CGSize, extent: Double) -> Double {
        fitScale(viewport: viewport, extent: extent) * 2.5
    }

    /// `OrbitLayout.snapshot`에 넘길 값. 기본 배율에서 0이고 2.5배에서 1이다.
    ///
    /// **닭과 달걀:** `extent`는 스냅샷에서 오는데 스냅샷을 만들려면 `zoomProgress`가
    /// 필요하다. 끊는 자리는 여기다 — `extent`는 어느 `Stage`에 상태가 몇 개인지에서만
    /// 나오고 줌과 무관하므로, 뷰는 `zoomProgress: 0`으로 스냅샷을 한 번 만들어
    /// `extent`를 얻은 뒤 실제 줌으로 다시 만든다. 둘 다 순수 함수라 값이 흔들리지 않는다.
    var zoomProgress: Double {
        let base = Self.fitScale(viewport: viewport, extent: extent)
        let spread = Self.spreadScale(viewport: viewport, extent: extent)
        guard spread > base else { return 1 }
        return min(max((scale - base) / (spread - base), 0), 1)
    }

    /// 티켓 키를 행성 옆에 적을 만큼 확대했는가. 줌아웃 상태에서 키 수십 개를 겹쳐
    /// 그리면 읽을 수 없는 글자 덩어리가 된다.
    var showsPlanetLabels: Bool { zoomProgress > 0.5 }

    func length(_ logical: Double) -> Double { logical * scale }

    func point(_ logical: OrbitPoint) -> CGPoint {
        CGPoint(x: viewport.width / 2 + logical.x * scale + pan.width,
                y: viewport.height / 2 + logical.y * scale + pan.height)
    }

    func planetPoint(system: OrbitSystem, planet: OrbitPlanet) -> CGPoint {
        point(OrbitGeometry.point(center: system.center,
                                  radius: planet.radius, angle: planet.angle))
    }

    /// 떠돌이는 소속 태양이 없다. 원점을 감싸는 바깥 고리에 놓인다.
    func driftPoint(_ planet: OrbitPlanet) -> CGPoint {
        point(OrbitGeometry.point(center: OrbitPoint(x: 0, y: 0),
                                  radius: planet.radius, angle: planet.angle))
    }

    /// 행성 지름. 줌에 비례해 커진다 — 확대했는데 점 크기가 그대로면
    /// 가까이 간 느낌이 나지 않는다.
    func diameter(for planet: OrbitPlanet) -> Double {
        length(OrbitLayout.planetArc) * planet.sizeFactor
    }
}
