import SwiftUI
import ArcadeApp
import ArcadeCore

/// 어느 단계에도 매핑되지 않은 상태의 티켓.
///
/// 접어 두는 이유: 이 목록이 비어 있는 것이 정상이고, 늘 펼쳐 두면 레인 넷보다
/// 먼저 눈에 들어온다. 개수는 접힌 상태에서도 항상 보인다.
struct UnmappedLaneView: View {
    @Environment(\.arcadeTheme) private var theme
    let issues: [ObservedIssue]
    let model: AppModel

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(isExpanded ? "▾ 매핑되지 않은 상태" : "▸ 매핑되지 않은 상태")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.danger)
                    Spacer()
                    // 플로어 마퀴의 배지는 **상태 개수**를 센다. 여기는 티켓 건수다 —
                    // 두 숫자는 다를 수 있으므로 문구로 구분한다.
                    Text("티켓 \(issues.count)건")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.inkTertiary)
                        .monospacedDigit()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(issues) { issue in
                        HStack(spacing: 8) {
                            Text(issue.key)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(theme.inkPrimary)
                            Text(issue.statusName)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.danger)
                            Text(issue.summary)
                                .font(.system(size: 10))
                                .foregroundStyle(theme.inkSecondary)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    // 마법사는 phase를 바꾸므로 RootView가 화면 전체를 갈아끼우고 보드는
                    // 닫힌다. 마치면 플로어로 돌아오며 사용자가 보드를 다시 연다.
                    Button("매핑 고치기") { Task { await model.reopenMapping() } }
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.top, 4)
                }
                .padding(.leading, 12)
            }
        }
        .padding(12)
        .background(theme.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.danger, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
