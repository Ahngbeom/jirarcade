import SwiftUI
import ArcadeApp

/// 티켓 하나를 읽고, 제목을 고치고, 댓글을 단다.
///
/// 판단은 전부 `AppModel`에 있다 — 이 파일에는 테스트가 닿지 않으므로 무엇을
/// 보여줄지 고르는 코드를 두지 않는다.
struct TicketDetailSheet: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let issueKey: String
    let model: AppModel

    @State private var summaryDraft = ""
    @State private var commentDraft = ""
    // 댓글 등록이 `openDetail`을 다시 불러 `.loaded`가 새로 그려질 때마다
    // `onAppear`가 또 fire한다 — 그때마다 다시 시딩하면 아직 저장하지 않은
    // 제목 수정이 지워진다. 시트 하나당 한 번만 시딩한다.
    @State private var hasSeededSummaryDraft = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 520, height: 560)
        .background(theme.surfaceBase)
        .task { await model.openDetail(issueKey: issueKey) }
        .onDisappear { model.closeDetail() }
    }

    private var header: some View {
        HStack {
            Text(issueKey)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.inkPrimary)
            Spacer()
            Button("닫기") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.inkTertiary)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch model.detailState {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.danger)
                Button("다시 시도") { Task { await model.openDetail(issueKey: issueKey) } }
                    .font(.system(size: 11, design: .monospaced))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let detail):
            loaded(detail)
        }
    }

    private func loaded(_ detail: IssueDetailView) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let failure = model.editFailures[issueKey] {
                    HStack {
                        Text(failure)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.danger)
                        Spacer()
                        Button("닫기") { model.dismissEditFailure(issueKey: issueKey) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(theme.inkTertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("제목").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.inkTertiary)
                    TextField("", text: $summaryDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                    Button("제목 저장") {
                        Task { await model.saveSummary(issueKey: issueKey, summary: summaryDraft) }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .disabled(model.editInFlight.contains(issueKey)
                              || summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || summaryDraft == detail.summary)
                }
                .onAppear {
                    guard !hasSeededSummaryDraft else { return }
                    hasSeededSummaryDraft = true
                    summaryDraft = detail.summary
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("본문").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.inkTertiary)
                    Text(detail.descriptionText.isEmpty ? "본문이 없습니다" : detail.descriptionText)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.inkPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("댓글").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.inkTertiary)
                    CommentListView(comments: detail.comments)
                    TextEditor(text: $commentDraft)
                        .font(.system(size: 12))
                        .frame(height: 72)
                        .border(theme.inkTertiary.opacity(0.3))
                    Button("댓글 등록") {
                        Task {
                            let posted = await model.postComment(issueKey: issueKey, text: commentDraft)
                            // 실패했으면(401 포함) 입력을 지우지 않고 다시 시도할 수 있게
                            // 그대로 둔다. `editFailures`의 유무로는 이걸 알 수 없다 — 401은
                            // 만료 배너와 중복되지 않도록 일부러 비워 두므로 `postComment`의
                            // 반환값을 그대로 읽는다.
                            guard posted else { return }
                            commentDraft = ""
                            await model.openDetail(issueKey: issueKey)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .disabled(model.editInFlight.contains(issueKey)
                              || commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
        }
    }
}
