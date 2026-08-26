import SwiftUI
import ArcadeApp

/// 티켓 하나를 읽고, 제목을 고치고, 댓글을 단다.
///
/// 판단은 전부 `AppModel`에 있다 — 이 파일에는 테스트가 닿지 않으므로 무엇을
/// 보여줄지 고르는 코드를 두지 않는다.
struct TicketDetailSheet: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var metrics
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
        .background(theme.surfaceBase)
        .task { await model.openDetail(issueKey: issueKey) }
        .onDisappear { model.closeDetail() }
    }

    private var header: some View {
        HStack {
            Text(issueKey)
                .arcadeType(.readout, .m, weight: .bold)
                .foregroundStyle(theme.inkPrimary)
            Spacer()
            Button("닫기") { dismiss() }
                .buttonStyle(.plain)
                .arcadeType(.readout, .xs)
                .foregroundStyle(theme.inkTertiary)
        }
        .padding(.horizontal, metrics.gutter)
        .padding(.vertical, metrics.rowGap)
    }

    @ViewBuilder
    private var content: some View {
        switch model.detailState {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: metrics.rowGap) {
                Text(message)
                    .arcadeType(.prose, .xs)
                    .foregroundStyle(theme.danger)
                Button("다시 시도") { Task { await model.openDetail(issueKey: issueKey) } }
                    .arcadeType(.readout, .xs)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let detail):
            loaded(detail)
        }
    }

    private func loaded(_ detail: IssueDetailView) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.sectionGap) {
                if let failure = model.editFailures[issueKey] {
                    HStack {
                        Text(failure)
                            .arcadeType(.prose, .xs)
                            .foregroundStyle(theme.danger)
                        Spacer()
                        Button("닫기") { model.dismissEditFailure(issueKey: issueKey) }
                            .buttonStyle(.plain)
                            .arcadeType(.readout, .xs)
                            .foregroundStyle(theme.inkTertiary)
                    }
                }

                VStack(alignment: .leading, spacing: metrics.tightGap) {
                    Text("제목").arcadeType(.readout, .xs)
                        .foregroundStyle(theme.inkTertiary)
                    TextField("", text: $summaryDraft)
                        .textFieldStyle(.roundedBorder)
                        .arcadeType(.prose, .s)
                    Button("제목 저장") {
                        Task { await model.saveSummary(issueKey: issueKey, summary: summaryDraft) }
                    }
                    .arcadeType(.readout, .xs)
                    .disabled(model.editInFlight.contains(issueKey)
                              || summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || summaryDraft == detail.summary)
                }
                .onAppear {
                    guard !hasSeededSummaryDraft else { return }
                    hasSeededSummaryDraft = true
                    summaryDraft = detail.summary
                }

                VStack(alignment: .leading, spacing: metrics.tightGap) {
                    Text("본문").arcadeType(.readout, .xs)
                        .foregroundStyle(theme.inkTertiary)
                    if detail.description.isEmpty {
                        Text("본문이 없습니다")
                            .arcadeType(.prose, .xs)
                            .foregroundStyle(theme.inkTertiary)
                    } else {
                        RichTextView(document: detail.description)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: metrics.tightGap) {
                    Text("댓글").arcadeType(.readout, .xs)
                        .foregroundStyle(theme.inkTertiary)
                    CommentListView(comments: detail.comments)
                    TextEditor(text: $commentDraft)
                        .arcadeType(.prose, .xs)
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
                    .arcadeType(.readout, .xs)
                    .disabled(model.editInFlight.contains(issueKey)
                              || commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(metrics.gutter)
        }
    }
}
