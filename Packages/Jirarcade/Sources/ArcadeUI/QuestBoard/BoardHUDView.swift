import SwiftUI
import ArcadeApp
import ArcadeCore

/// 보드 상단 한 줄 — 시즌 레벨·XP·연속·HP·위생과 다음 한 걸음.
///
/// 시즌을 보여주는 이유는 `ArcadeFloorView`와 같다: 오늘 하나 처리한 것이 움직여야 한다.
struct BoardHUDView: View {
    @Environment(\.arcadeTheme) private var theme
    let model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            if let season = model.seasonSummary {
                Text("LV.\(season.level)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.accent)
                ProgressView(value: Double(season.xpIntoLevel),
                             total: Double(max(season.xpForNextLevel, 1)))
                    .tint(theme.accent)
                    .frame(width: 110)
                Text("\(season.xpIntoLevel)/\(season.xpForNextLevel)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.inkTertiary)
                    .monospacedDigit()
                Text("연속 \(season.streak.currentStreak)일")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.inkSecondary)
                    .monospacedDigit()
            }
            if let hygiene = model.hygiene {
                Text(hpLabel(hygiene.hp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(hygiene.hp == 0 ? theme.danger : theme.good)
                Text("위생 \(hygiene.score)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.inkSecondary)
                    .monospacedDigit()
                if let step = hygiene.nextStep {
                    Text(nextStepLabel(step))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.inkTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func hpLabel(_ hp: Int) -> String {
        String(repeating: "♥", count: hp) + String(repeating: "♡", count: max(0, 3 - hp))
    }

    /// `HygieneNextStep`은 구조화된 값이다. 문장으로 만드는 일은 뷰가 한다 —
    /// `HygieneCalculator`의 doc-comment가 정한 경계다.
    private func nextStepLabel(_ step: HygieneNextStep) -> String {
        switch step {
        case .reduceWIP(let to, let gain):
            return "진행 중을 \(to)건까지 줄이면 위생 +\(gain)"
        case .touchZombies(let count, let gain):
            return "오래 멈춘 \(count)건을 움직이면 위생 +\(gain)"
        case .resolveGhosts(let count, let gain):
            return "마감 지난 \(count)건을 정리하면 위생 +\(gain)"
        }
    }
}
