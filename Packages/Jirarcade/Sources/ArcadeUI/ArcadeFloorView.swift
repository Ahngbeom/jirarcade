import SwiftUI
import ArcadeApp

struct ArcadeFloorView: View {
    @Environment(\.arcadeTheme) private var theme
    let model: AppModel

    @State private var openCabinetID: String?

    /// 셸이 아는 것은 이 배열뿐이다. 2b에서 캐비닛을 더할 때 이 줄만 늘어난다.
    private var cabinets: [any Cabinet] {
        [ObservationCabinet(model: model)]
    }

    var body: some View {
        VStack(spacing: 0) {
            marquee
            Divider().overlay(theme.line)
            cabinetRow
            Divider().overlay(theme.line)
            statusBar
        }
        .background(theme.surfaceBase)
        .sheet(item: Binding(
            get: { openCabinetID.map(OpenCabinet.init) },
            set: { openCabinetID = $0?.id }
        )) { open in
            VStack {
                HStack {
                    Spacer()
                    Button("닫기") { openCabinetID = nil }.keyboardShortcut(.cancelAction)
                }
                .padding()
                if let cabinet = cabinets.first(where: { $0.id == open.id }) {
                    cabinet.makeView()
                } else {
                    // id가 가리키는 캐비닛이 더 이상 없다 — 강제 언래핑 대신 빈 안내로 넘긴다.
                    Text("캐비닛을 찾을 수 없습니다").foregroundStyle(theme.inkTertiary)
                }
                Spacer()
            }
            .frame(minWidth: 420, minHeight: 320)
            .background(theme.surfaceBase)
            .environment(\.arcadeTheme, theme)
        }
    }

    private var marquee: some View {
        HStack(spacing: 12) {
            Text("▨ ARCADE FLOOR ▨")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.accent)
            Spacer()
            if !model.unmappedStatuses.isEmpty {
                Text("⚠ 매핑되지 않은 상태 \(model.unmappedStatuses.count)개")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.danger)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var cabinetRow: some View {
        HStack(spacing: 16) {
            ForEach(cabinets, id: \.id) { cabinet in
                cabinetCard(cabinet)
            }
            comingSoon()
            comingSoon()
        }
        .padding(20)
    }

    private func cabinetCard(_ cabinet: any Cabinet) -> some View {
        VStack(spacing: 0) {
            Text(cabinet.title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.surfaceBase)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(theme.color(forToken: cabinet.accentToken))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(cabinet.marqueeLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.inkSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("▶ OPEN") { openCabinetID = cabinet.id }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 180)
        .background(theme.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func comingSoon() -> some View {
        VStack {
            Spacer()
            Text("COMING SOON")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.inkTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .background(theme.surfaceRaised.opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusBar: some View {
        HStack {
            Text(syncText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.inkTertiary)
            Spacer()
            Button("새로고침") { Task { await model.syncNow() } }
                .font(.system(size: 11, design: .monospaced))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var syncText: String {
        guard let sync = model.lastSync, let finished = sync.finishedAt else {
            return "아직 동기화하지 않았습니다"
        }
        return "마지막 동기화 \(finished.formatted(date: .omitted, time: .shortened))"
    }
}

/// sheet(item:)이 Identifiable을 요구하므로 감싼다.
private struct OpenCabinet: Identifiable { let id: String }
