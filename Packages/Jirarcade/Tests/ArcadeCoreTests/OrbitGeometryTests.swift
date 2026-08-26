import Testing
import Foundation
import CoreGraphics
@testable import ArcadeCore

/// 해시값을 리터럴로 굳혀 둔다. 이것이 `String.hashValue`로 되돌아가는 것을 막는
/// 유일한 방어다 — Swift의 기본 해시는 프로세스마다 무작위 시드를 쓰므로 앱을 다시
/// 열 때마다 모든 행성이 다른 자리로 간다. 화면은 매 실행 정상으로 보이고, 테스트는
/// 한 프로세스 안에서 도는 탓에 그 사실을 잡지 못한다.
@Test func hashesKeysToKnownValues() {
    #expect(OrbitGeometry.stableHash("DEMO-1") == 2_116_399_489_896_580_304)
    #expect(OrbitGeometry.stableHash("DEMO-2") == 2_116_402_788_431_464_937)
    #expect(OrbitGeometry.stableHash("DEMO-3") == 2_116_401_688_919_836_726)
}

@Test func mapsKeysToKnownAngles() {
    #expect(abs(OrbitGeometry.angle(forKey: "DEMO-1") - 3.646157566) < 1e-6)
    #expect(abs(OrbitGeometry.angle(forKey: "DEMO-2") - 2.921285327) < 1e-6)
}

@Test func keepsAnglesInsideOneTurn() {
    for index in 1...200 {
        let angle = OrbitGeometry.angle(forKey: "DEMO-\(index)")
        #expect(angle >= 0)
        #expect(angle < 2 * .pi)
    }
}

/// 각거리는 원을 도는 거리다. 0.1과 6.2는 수직선에서 6.1 떨어져 있지만
/// 원에서는 0.18쯤이다 — 이걸 틀리면 12시 근처 행성들이 겹친다.
@Test func measuresDistanceAroundTheCircle() {
    let distance = OrbitGeometry.angularDistance(0.1, 6.2)
    #expect(abs(distance - (2 * .pi - 6.1)) < 1e-9)
    #expect(distance <= .pi)
}

@Test func treatsAngularDistanceAsSymmetric() {
    let forward = OrbitGeometry.angularDistance(1.0, 4.0)
    let backward = OrbitGeometry.angularDistance(4.0, 1.0)
    #expect(abs(forward - backward) < 1e-12)
}

@Test func placesPointsOnTheCircleAroundTheirCenter() {
    let center = OrbitPoint(x: 2, y: -1)
    let east = OrbitGeometry.point(center: center, radius: 3, angle: 0)

    #expect(abs(east.x - 5) < 1e-9)
    #expect(abs(east.y - (-1)) < 1e-9)
}

/// 우선순위를 모르면 1.0이다. 모르는 값을 크거나 작게 그리면 없는 사실을 말하게 된다.
@Test func fallsBackToNeutralSizeForUnknownPriority() {
    #expect(OrbitGeometry.sizeFactor(forPriority: nil) == 1.0)
    #expect(OrbitGeometry.sizeFactor(forPriority: "긴급") == 1.0)
}

@Test func scalesPlanetsByJiraDefaultPriorities() {
    #expect(OrbitGeometry.sizeFactor(forPriority: "Highest") > OrbitGeometry.sizeFactor(forPriority: "High"))
    #expect(OrbitGeometry.sizeFactor(forPriority: "High") > OrbitGeometry.sizeFactor(forPriority: "Medium"))
    #expect(OrbitGeometry.sizeFactor(forPriority: "Medium") > OrbitGeometry.sizeFactor(forPriority: "Low"))
    #expect(OrbitGeometry.sizeFactor(forPriority: "Low") > OrbitGeometry.sizeFactor(forPriority: "Lowest"))
}

/// Jira 우선순위 이름의 대소문자는 사이트마다 다르다.
@Test func matchesPriorityNamesCaseInsensitively() {
    #expect(OrbitGeometry.sizeFactor(forPriority: "HIGHEST")
            == OrbitGeometry.sizeFactor(forPriority: "Highest"))
}

// MARK: - 커서 기준 확대

/// 확대해도 커서 아래 있던 것이 커서 아래 그대로 남아야 한다. 화면 좌표는
/// `viewport/2 + L·scale + pan`이므로, 커서의 중심 기준 오프셋을 `c`라 하면
/// `L = (c − pan) / scale`이고, 새 배율에서 같은 `L`이 `c`에 오려면
/// `pan' = c − L·scale'`이다.
@Test func zoomingKeepsThePointUnderTheCursorStill() {
    let cursor = CGPoint(x: 120, y: -40)      // 화면 중심 기준 오프셋
    let pan = CGSize(width: 30, height: 10)
    let oldScale = 200.0, newScale = 300.0

    let kept = OrbitGeometry.panKeepingPointUnderCursor(
        cursorOffset: cursor, pan: pan, oldScale: oldScale, newScale: newScale
    )

    // 확대 전 커서 아래 논리 좌표
    let logicalX = (cursor.x - pan.width) / oldScale
    let logicalY = (cursor.y - pan.height) / oldScale
    // 확대 후 그 논리 좌표의 화면 위치는 여전히 커서다
    #expect(abs(logicalX * newScale + kept.width - cursor.x) < 1e-9)
    #expect(abs(logicalY * newScale + kept.height - cursor.y) < 1e-9)
}

/// 커서가 화면 중심에 있으면 `anchoredPan`(비례 보정)과 같은 답이어야 한다 — 두 식이
/// 다른 답을 내면 어느 쪽이 맞는지 알 수 없다.
@Test func zoomingAtTheCentreIsPlainProportionalScaling() {
    let pan = CGSize(width: 50, height: -20)

    let kept = OrbitGeometry.panKeepingPointUnderCursor(
        cursorOffset: CGPoint(x: 0, y: 0), pan: pan, oldScale: 100, newScale: 250
    )

    #expect(abs(kept.width - 125) < 1e-9)
    #expect(abs(kept.height - -50) < 1e-9)
}

/// 배율이 그대로면 팬도 그대로다.
@Test func anUnchangedScaleLeavesThePanAlone() {
    let pan = CGSize(width: 7, height: 9)
    let kept = OrbitGeometry.panKeepingPointUnderCursor(
        cursorOffset: CGPoint(x: 300, y: 200), pan: pan, oldScale: 80, newScale: 80
    )
    #expect(kept.width == pan.width && kept.height == pan.height)
}

/// 배율 0은 나눌 수 없다. 죽는 대신 팬을 그대로 둔다 — 화면이 멈추는 것보다 낫다.
@Test func aZeroScaleDoesNotDivide() {
    let pan = CGSize(width: 7, height: 9)
    let kept = OrbitGeometry.panKeepingPointUnderCursor(
        cursorOffset: CGPoint(x: 10, y: 10), pan: pan, oldScale: 0, newScale: 80
    )
    #expect(kept.width == pan.width && kept.height == pan.height)
}
