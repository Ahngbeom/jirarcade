import SwiftUI
import ArcadeCore

/// 티켓 하나를 화면에 적는 규칙. 카드·행성·팝오버가 같은 티켓을 다르게 적지 않도록
/// 한 곳에 모았다.
///
/// 이 파일이 생긴 이유: 같은 판단이 세 뷰에 복제돼 있었고, 그 복제가 실제로 두 번
/// 어긋났다 — 마감 색이 카드에서는 accent인데 행성에서는 danger였고, 팝오버는
/// "오늘 마감"을 "D-0"으로 적었다(둘 다 이 브랜치에서 먼저 고쳐졌다). 판단이 복제로
/// 남아 있는 한 세 번째 어긋남은 시간 문제다.
///
/// `TicketCardView`가 정본이다 — 가장 오래된 판단이고, 앞선 두 수정도 카드에 맞추는
/// 방향이었다. 색은 `ArcadeTheme`를 인자로 받아 그 프로퍼티만 돌려준다
/// (`ModuleBoundaryTests`의 색 리터럴 검사가 `ArcadeUI` 전체에 걸리기 때문이다).
enum TicketPresentation {
    /// 정체 등급 색.
    static func tierColor(_ tier: StagnationTier, theme: ArcadeTheme) -> Color {
        switch tier {
        case .fresh: theme.line
        case .stale: theme.accent
        case .boss, .raid: theme.boss
        }
    }

    /// 정체 등급 라벨.
    static func tierLabel(_ tier: StagnationTier) -> String {
        switch tier {
        case .fresh: "·"
        case .stale: "STALE"
        case .boss:  "BOSS"
        case .raid:  "RAID"
        }
    }

    /// 마감 색. 강조 기준은 뷰의 몫이다(`ArcadeCore`의 `DueState`는 사실만 담는다).
    /// D-3 이내부터 눈에 띄게 한다.
    static func dueColor(_ due: DueState, theme: ArcadeTheme) -> Color {
        switch due {
        case .none:             theme.inkTertiary
        case .overdue:          theme.danger
        case .dueIn(let days):  days <= 3 ? theme.accent : theme.inkTertiary
        }
    }

    /// 마감 문구. 마감이 없으면 `nil`이다.
    static func dueLabel(_ due: DueState) -> String? {
        switch due {
        case .none: nil
        case .overdue(let days): "\(days)일 지남"
        case .dueIn(let days): days == 0 ? "오늘 마감" : "D-\(days)"
        }
    }

    /// 근사값에 `~`를 붙인다. 관측 이력이 없는 티켓의 정체일을 확정처럼 보여주면
    /// "관측한 것만 안다"는 이 앱의 원칙이 화면에서 깨진다.
    static func stagnationLabel(days: Int, isApproximate: Bool) -> String {
        (isApproximate ? "~" : "") + "\(days)d"
    }

    /// 스프린트 이월 툴팁. 첫 스프린트와 최신 스프린트가 같으면 하나만 적는다.
    static func sprintTooltip(first: String?, latest: String?) -> String {
        guard let first, let latest else { return "" }
        return first == latest ? first : "\(first) → \(latest)"
    }

    /// `Stage` 라벨. 보드 레인과 궤도 태양이 같은 이름을 써야 두 화면이 같은 데이터의
    /// 두 시선이라는 것이 읽힌다.
    static func stageLabel(_ stage: Stage) -> String {
        switch stage {
        case .backlog: "BACKLOG"
        case .active:  "ACTIVE"
        case .review:  "REVIEW"
        case .verify:  "VERIFY"
        case .done:    "DONE"
        }
    }
}
