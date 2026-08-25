import Foundation

/// 궤도 화면의 논리 좌표 한 점. **pt가 아니다** — 1.0이 궤도 최대 반경이고,
/// 픽셀로 옮기는 일은 뷰가 한다(`OrbitMetrics`).
public struct OrbitPoint: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// 궤도 배치의 기하 계산. 티켓도 화면도 모른다.
public enum OrbitGeometry {
    /// FNV-1a 64비트.
    ///
    /// `String.hashValue`를 쓰지 않는 이유: Swift의 기본 해시는 **프로세스마다 무작위
    /// 시드**를 쓴다. 같은 티켓 키가 앱을 다시 열 때마다 다른 값을 내고, 그러면 어제
    /// 눈여겨본 티켓이 오늘 다른 자리에 있다. 화면은 매 실행 정상으로 보이므로 이 결함은
    /// 눈으로 잡히지 않고, 테스트는 한 프로세스 안에서 도는 탓에 잡지 못한다.
    ///
    /// 표준 라이브러리에는 프로세스 간 안정성을 보장하는 해시가 없으므로 직접 갖는다.
    public static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// 티켓 키를 궤도 위 각도로 옮긴다. 같은 키는 언제나 같은 각도를 얻는다.
    ///
    /// 해시를 100만으로 나눈 나머지를 쓰는 이유는 `UInt64.max`를 `Double`로 옮길 때
    /// 생기는 반올림을 피하기 위해서다. 100만 분해능이면 지름 몇 pt짜리 행성에는
    /// 넉넉하다.
    public static func angle(forKey key: String) -> Double {
        Double(stableHash(key) % 1_000_000) / 1_000_000 * 2 * .pi
    }

    /// 두 각 사이의 **원형** 거리(0…π). 수직선 거리를 쓰면 12시 근처에서
    /// 0.1과 6.2가 멀리 떨어진 것으로 판정돼 그 자리의 행성들이 겹친다.
    public static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let turn = 2 * Double.pi
        let delta = abs(a - b).truncatingRemainder(dividingBy: turn)
        return min(delta, turn - delta)
    }

    /// 극좌표를 논리 좌표로 옮긴다.
    public static func point(center: OrbitPoint, radius: Double, angle: Double) -> OrbitPoint {
        OrbitPoint(x: center.x + radius * cos(angle),
                   y: center.y + radius * sin(angle))
    }

    /// 우선순위를 행성 지름 배율로 옮긴다.
    ///
    /// Jira 기본 우선순위 다섯만 안다. 조직이 이름을 바꿨거나 우선순위를 쓰지 않으면
    /// 1.0이다 — 모르는 값을 크거나 작게 그리면 없는 사실을 말하게 된다.
    public static func sizeFactor(forPriority priority: String?) -> Double {
        switch priority?.lowercased() {
        case "highest": 1.5
        case "high":    1.25
        case "medium":  1.0
        case "low":     0.85
        case "lowest":  0.75
        default:        1.0
        }
    }
}
