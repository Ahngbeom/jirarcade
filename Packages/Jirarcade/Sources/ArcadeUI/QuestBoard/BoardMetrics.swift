import SwiftUI

/// 정규화 위치(0…1)를 pt로 옮기는 곱셈만 모은 값 타입.
///
/// 판단은 `BoardLayout`이 이미 끝냈다 — 여기에는 등급 판정도 정렬도 없다.
/// 그래서 `ArcadeUI`에 테스트 타깃이 없어도 위험이 낮다.
struct BoardMetrics {
    let availableWidth: Double

    let cardWidth: Double = 132
    let cardHeight: Double = 96
    let rowGap: Double = 8
    /// 카드 사이에 최소로 남길 여백. 이보다 좁아지면 `LanePacker`가 다음 줄로 내린다.
    let cardGap: Double = 10

    /// 카드가 놓일 수 있는 폭. position 1.0인 카드의 오른쪽 끝이 축의 끝과 맞는다.
    var usableWidth: Double { max(availableWidth - cardWidth, 1) }

    /// `BoardLayout.snapshot(minimumSpacing:)`에 넘길 값.
    /// 창을 좁히면 이 값이 커져 자연히 더 많이 쌓인다.
    var minimumSpacing: Double { (cardWidth + cardGap) / usableWidth }

    func x(for position: Double) -> Double { position * usableWidth }

    func y(forRow row: Int) -> Double { Double(row) * (cardHeight + rowGap) }

    /// 슬롯이 없으면 0이 아니라 한 줄 높이를 준다 — 빈 레인도 축은 그려야
    /// "여기에 아무것도 없다"가 보인다.
    func laneHeight(rowCount: Int) -> Double {
        Double(max(rowCount, 1)) * cardHeight + Double(max(rowCount - 1, 0)) * rowGap
    }
}
