import SwiftUI

/// 정규화 위치(0…1)를 pt로 옮기는 곱셈만 모은 값 타입.
///
/// 판단은 `BoardLayout`이 이미 끝냈다 — 여기에는 등급 판정도 정렬도 없다.
/// 그래서 `ArcadeUI`에 테스트 타깃이 없어도 위험이 낮다.
struct BoardMetrics {
    let availableWidth: Double

    let cardWidth: Double = 132
    /// 전이 실패 블록(2줄 메시지 + Jira 링크)이 최악의 경우에도 잘리지 않을 높이.
    /// 마감일 줄은 실패가 뜨는 동안 숨는다(`TicketCardView.showsFailureBlock`) — 그래도
    /// 두 상태 모두 이 높이 안에 들어오는지는 `TicketCardView`의 계산에서 확인한다.
    ///
    /// 콘텐츠 박스는 `cardHeight`(120) − 상하 패딩 16pt = 104pt, `VStack` 줄 간격은 3pt다.
    /// 실측 폰트 메트릭 기준 줄 높이:
    ///   - 보통(마감일 + 이월 + 상태 옮기기 메뉴, 6줄): ~103pt — 가장 빠듯한 상태
    ///   - 대기(마감일 + 이월 + 대기 줄, 6줄): 96pt
    ///   - 실패(마감일·이월 숨김 + 실패 블록): 104pt 안에 들어온다
    /// 옛 높이 112pt에서는 이 "보통" 상태의 콘텐츠 박스가 정확히 꽉 차 여유가 0pt였다 —
    /// 그래서 120pt로 올렸다. 지금도 가장 빠듯한 쪽은 여전히 "보통" 상태이므로, 이 값을
    /// 다시 낮추려면 그 줄부터 다시 재야 한다.
    let cardHeight: Double = 120
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
