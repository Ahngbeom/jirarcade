import Foundation

/// 궤도 위 좌석 하나. 티켓을 모르고 좌표만 안다.
public struct OrbitSeat: Sendable, Equatable {
    public let key: String
    public let radius: Double
    public let angle: Double

    public init(key: String, radius: Double, angle: Double) {
        self.key = key
        self.radius = radius
        self.angle = angle
    }
}

/// 같은 태양에 속한 행성이 서로 가리지 않게 민다.
///
/// 보드의 `LanePacker`와 같은 문제를 원에서 푼다. 다른 점은 **아랫줄이 없다**는 것이다 —
/// 각도로 먼저 풀고, 한 바퀴가 포화했을 때에만 반경을 민다. 반경을 먼저 밀면 정체일과
/// 거리의 대응이 필요 이상으로 어긋난다.
public enum OrbitPacker {
    /// 반경을 미는 횟수의 상한. 궤도 최대 반경 1.0을 가장 작은 `planetArc`로 나눈 것보다
    /// 넉넉하다. 상한이 없으면 잘못된 입력에서 무한 루프가 된다.
    private static let ringLimit = 32

    /// 두 행성이 같은 반경대에서 겹치지 않기 위해 필요한 최소 각거리.
    ///
    /// 호 길이 = 반경 × 각도이므로 각도는 반경에 반비례한다 — 안쪽일수록 더 크게 벌려야
    /// 같은 간격이 난다. π로 막는 이유: 반경이 0에 가까우면 몫이 무한대로 발산해
    /// 좌석 하나를 놓는 데 영원히 돌거나 NaN이 좌표로 흘러든다.
    public static func minimumAngle(radius: Double, planetArc: Double) -> Double {
        guard radius > 0 else { return .pi }
        return min(planetArc / radius, .pi)
    }

    /// 좌석을 키 오름차순으로 하나씩 앉힌다.
    ///
    /// 정렬하는 이유는 입력 순서가 미러 딕셔너리 순회에서 오기 때문이다 —
    /// `BoardLayout`이 미매핑 목록을 정렬하는 것과 같은 이유이며, 정렬하지 않으면
    /// 같은 데이터가 실행마다 다른 배치를 낳는다.
    public static func pack(_ seats: [OrbitSeat], planetArc: Double) -> [OrbitSeat] {
        var placed: [OrbitSeat] = []
        for seat in seats.sorted(by: { $0.key < $1.key }) {
            placed.append(settle(seat, among: placed, planetArc: planetArc))
        }
        return placed
    }

    private static func settle(
        _ seat: OrbitSeat, among placed: [OrbitSeat], planetArc: Double
    ) -> OrbitSeat {
        var radius = seat.radius

        for _ in 0..<ringLimit {
            let step = minimumAngle(radius: radius, planetArc: planetArc)
            // 한 바퀴에 시도할 수 있는 자리 수. step이 π면 두 자리뿐이다.
            let stops = max(Int((2 * Double.pi / step).rounded(.down)), 1)
            var angle = seat.angle

            for _ in 0..<stops {
                if !collides(radius: radius, angle: angle, with: placed, planetArc: planetArc) {
                    return OrbitSeat(key: seat.key, radius: radius, angle: angle)
                }
                angle = (angle + step).truncatingRemainder(dividingBy: 2 * .pi)
            }
            radius += planetArc
        }

        // 여기 닿으면 입력이 비정상이다(같은 자리에 수백 개). 마지막 반경에 원래 각도로
        // 둔다 — 겹칠지언정 화면 밖으로 내보내거나 크래시시키지 않는다.
        return OrbitSeat(key: seat.key, radius: radius, angle: seat.angle)
    }

    private static func collides(
        radius: Double, angle: Double, with placed: [OrbitSeat], planetArc: Double
    ) -> Bool {
        placed.contains { other in
            guard abs(other.radius - radius) < planetArc else { return false }
            let needed = minimumAngle(radius: max(other.radius, radius), planetArc: planetArc)
            return OrbitGeometry.angularDistance(other.angle, angle) < needed
        }
    }
}
