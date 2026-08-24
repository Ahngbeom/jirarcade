import SwiftUI
import ArcadeApp

/// 댓글 목록. 각 댓글의 저자·시각·본문은 `AppModel`이 이미 ADF에서 풀어 넘긴다.
struct CommentListView: View {
    @Environment(\.arcadeTheme) private var theme
    let comments: [CommentView]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(comment.authorName)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(theme.inkSecondary)
                        Text(comment.created, style: .date)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(theme.inkTertiary)
                    }
                    Text(comment.text)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.inkPrimary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
