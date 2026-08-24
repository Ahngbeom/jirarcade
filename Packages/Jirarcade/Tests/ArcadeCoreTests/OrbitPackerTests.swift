import Testing
import Foundation
@testable import ArcadeCore

private let arc = 0.12

private func seat(_ key: String, radius: Double, angle: Double) -> OrbitSeat {
    OrbitSeat(key: key, radius: radius, angle: angle)
}

/// 겹침 판정을 테스트가 직접 다시 정의하지 않는다 — 구현과 같은 규칙을 쓴다.
private func overlaps(_ a: OrbitSeat, _ b: OrbitSeat) -> Bool {
    abs(a.radius - b.radius) < arc
        && OrbitGeometry.angularDistance(a.angle, b.angle)
            < OrbitPacker.minimumAngle(radius: max(a.radius, b.radius), planetArc: arc)
}

@Test func returnsEmptyForEmptyInput() {
    #expect(OrbitPacker.pack([], planetArc: arc).isEmpty)
}

@Test func leavesASingleSeatWhereItIs() {
    let only = seat("DEMO-1", radius: 0.5, angle: 1.0)
    let packed = OrbitPacker.pack([only], planetArc: arc)

    #expect(packed == [only])
}

/// 완전히 같은 자리에 들어온 다섯이 서로 떨어져야 한다. 이게 이 타입의 존재 이유다.
@Test func separatesSeatsThatArrivedAtTheSameSpot() {
    let crowd = (1...5).map { seat("DEMO-\($0)", radius: 0.5, angle: 2.0) }
    let packed = OrbitPacker.pack(crowd, planetArc: arc)

    #expect(packed.count == 5)
    for outer in packed {
        for inner in packed where inner.key != outer.key {
            #expect(!overlaps(outer, inner), "\(outer.key)와 \(inner.key)가 겹친다")
        }
    }
}

/// 입력 순서는 미러 딕셔너리 순회에서 오므로 불안정하다. 결과는 그것과 무관해야 한다.
@Test func packsTheSameRegardlessOfInputOrder() {
    let crowd = (1...5).map { seat("DEMO-\($0)", radius: 0.5, angle: 2.0) }
    let forward = OrbitPacker.pack(crowd, planetArc: arc)
    let backward = OrbitPacker.pack(crowd.reversed(), planetArc: arc)

    #expect(forward == backward)
}

/// 안쪽 궤도는 둘레가 짧아 각도만으로 풀 수 없다. 그때는 반경이 밀린다.
@Test func pushesRadiusOutwardWhenTheInnerRingIsFull() {
    let crowd = (1...8).map { seat("DEMO-\($0)", radius: 0.15, angle: 0.0) }
    let packed = OrbitPacker.pack(crowd, planetArc: arc)

    #expect(packed.contains { $0.radius > 0.15 })
    for outer in packed {
        for inner in packed where inner.key != outer.key {
            #expect(!overlaps(outer, inner), "\(outer.key)와 \(inner.key)가 겹친다")
        }
    }
}

/// 반경이 작을수록 같은 호 길이를 얻는 데 더 큰 각도가 필요하다.
@Test func requiresWiderAnglesOnInnerOrbits() {
    let inner = OrbitPacker.minimumAngle(radius: 0.2, planetArc: arc)
    let outer = OrbitPacker.minimumAngle(radius: 0.9, planetArc: arc)

    #expect(inner > outer)
}

/// 반경 0에서 호 길이를 각도로 나누면 무한대가 된다. π로 막지 않으면 좌석 하나를
/// 놓는 데 무한히 돌거나 NaN이 좌표로 흘러든다.
@Test func clampsMinimumAngleToHalfTurn() {
    #expect(OrbitPacker.minimumAngle(radius: 0, planetArc: arc) <= .pi)
}

/// 이미 흩어져 들어온 좌석은 건드리지 않는다.
@Test func leavesWellSpreadSeatsUntouched() {
    let spread = (0..<4).map { index in
        seat("DEMO-\(index)", radius: 0.6, angle: Double(index) * .pi / 2)
    }
    let packed = OrbitPacker.pack(spread, planetArc: arc)

    #expect(packed.sorted { $0.key < $1.key } == spread.sorted { $0.key < $1.key })
}
