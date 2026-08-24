import SwiftUI

/// 정규화 위치(0…1)를 pt로 옮기는 곱셈만 모은 값 타입.
///
/// 판단은 `BoardLayout`이 이미 끝냈다 — 여기에는 등급 판정도 정렬도 없다.
/// 그래서 `ArcadeUI`에 테스트 타깃이 없어도 위험이 낮다.
///
/// 치수는 `ArcadeMetrics`에서 받는다. 상수로 들고 있으면 넓은 화면에서 축만 늘어나고
/// 카드는 그대로라 정보 밀도가 떨어진다 — 카드가 함께 커지면 `minimumSpacing`도 함께
/// 커져 `LanePacker`가 자연히 더 여유 있게 쌓는다(패킹 규칙 자체는 그대로다).
struct BoardMetrics {
    let availableWidth: Double

    let cardWidth: Double
    /// 전이 실패 블록(2줄 메시지 + Jira 링크)이 최악의 경우에도 잘리지 않을 높이.
    /// 마감일 줄은 실패가 뜨는 동안 숨는다(`TicketCardView.showsFailureBlock`) — 그래도
    /// 두 상태 모두 이 높이 안에 들어오는지는 `TicketCardView`의 계산에서 확인한다.
    ///
    /// 예산이 가장 빠듯한 쪽은 글자도 여백도 가장 작은 compact다. 그 밀도의 콘텐츠
    /// 박스는 `ticketCardHeight`(120) − 상하 패딩 16pt = 104pt, `VStack` 줄 간격은
    /// 3pt다. 실측 폰트 메트릭 기준 줄 높이:
    ///   - 보통(마감일 + 이월 + 상태 옮기기 메뉴, 6줄): ~103pt — 가장 빠듯한 상태
    ///   - 대기(마감일 + 이월 + 대기 줄, 6줄): 96pt
    ///   - 실패(마감일·이월 숨김 + 실패 블록): 104pt 안에 들어온다
    /// compact가 112pt였을 때 이 "보통" 상태의 콘텐츠 박스가 정확히 꽉 차 여유가
    /// 0pt였다 — 그래서 120pt로 올렸다. 지금도 가장 빠듯한 쪽은 여전히 "보통"
    /// 상태이므로, `ticketCardHeight`를 다시 낮추려면 그 줄부터 다시 재야 한다.
    ///
    /// 이 예산은 요약의 **둘째 줄까지는** 품지 못한다: 마감일과 이월이 함께 뜨면
    /// `lineLimit(2)`인 요약이 한 줄로 접힌다(세 밀도 모두). 잘리는 것이 아니라
    /// SwiftUI가 줄 수를 줄이는 것이므로 화면은 멀쩡하지만, 요약 두 줄이 필요하다면
    /// 높이를 늘리는 것 말고 다른 방법이 없다.
    let cardHeight: Double
    let rowGap: Double
    /// 카드 사이에 최소로 남길 여백. 이보다 좁아지면 `LanePacker`가 다음 줄로 내린다.
    let cardGap: Double
    /// 카드 안쪽 여백. 카드가 커지면 함께 커져야 글자가 모서리에 붙지 않는다.
    let cardPadding: Double
    /// 카드 안 줄 간격. 여백 토큰(`tightGap`)을 그대로 쓰지 않는 이유: 카드에는 최대
    /// 여섯 줄(등급·키·요약 2줄·마감일·대기/실패 블록)이 들어가므로 줄 간격 1pt가
    /// 높이 5pt를 먹는다. `cardHeight` 예산이 가장 빠듯한 compact에서 기존 3pt를
    /// 그대로 유지하도록 0.75를 곱한다.
    let cardLineGap: Double

    init(availableWidth: Double, metrics: ArcadeMetrics) {
        self.availableWidth = availableWidth
        self.cardWidth = metrics.size(.ticketCardWidth)
        self.cardHeight = metrics.size(.ticketCardHeight)
        self.rowGap = metrics.rowGap
        self.cardGap = metrics.size(.ticketCardGap)
        self.cardPadding = metrics.rowGap
        self.cardLineGap = metrics.tightGap * 0.75
    }

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
