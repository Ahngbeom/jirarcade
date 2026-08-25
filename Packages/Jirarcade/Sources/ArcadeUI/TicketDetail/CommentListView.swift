import SwiftUI
import ArcadeApp

/// 댓글 목록. 각 댓글의 저자·시각·본문은 `AppModel`이 이미 ADF에서 풀어 넘긴다.
struct CommentListView: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
    let comments: [CommentView]

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowGap) {
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: metrics.tightGap) {
                    HStack(spacing: metrics.tightGap) {
                        Text(comment.authorName)
                            .arcadeType(.readout, .xs, weight: .bold)
                            .foregroundStyle(theme.inkSecondary)
                        Text(comment.created, style: .date)
                            .arcadeType(.readout, .xs)
                            .foregroundStyle(theme.inkTertiary)
                    }
                    Text(comment.text)
                        .arcadeType(.prose, .xs)
                        .foregroundStyle(theme.inkPrimary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
