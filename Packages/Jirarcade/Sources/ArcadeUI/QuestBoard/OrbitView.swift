import SwiftUI
import ArcadeApp
import ArcadeCore

/// 상태별 태양계.
///
/// 좌표는 전부 `OrbitLayout`이 정했다. 이 뷰가 하는 일은 논리 좌표를 pt로 옮겨
/// 놓는 것과 제스처를 받는 것뿐이다.
struct OrbitView: View {
    @Environment(\.arcadeTheme) private var theme
    @Environment(\.arcadeMetrics) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: AppModel
    let cardNamespace: Namespace.ID

    /// nil이면 "전체가 보이는 배율". 창 크기가 바뀌어도 따라가게 하려고
    /// 절대값 대신 nil을 기본으로 둔다.
    @State private var scale: Double?
    @State private var committedPan: CGSize = .zero
    @State private var dragPan: CGSize = .zero
    @State private var gestureScale: Double = 1
    @State private var selected: String?

    var body: some View {
        GeometryReader { proxy in
            // 성계가 논리 좌표에서 얼마나 큰지 먼저 잰다. 크기는 어느 `Stage`에 상태가
            // 몇 개 접혔는지에서만 나오고 줌과 무관하므로, 줌 0으로 한 번 만들어
            // `extent`를 얻고 그 값으로 배율을 정한 뒤 실제 줌으로 다시 만든다.
            // 순수 함수 두 번이라 값이 흔들리지 않는다.
            let extent = model.orbitSnapshot(zoomProgress: 0).extent
            let base = scale ?? OrbitMetrics.fitScale(viewport: proxy.size, extent: extent)
            let metrics = OrbitMetrics(
                viewport: proxy.size,
                scale: clampScale(base * gestureScale, viewport: proxy.size, extent: extent),
                pan: CGSize(width: committedPan.width + dragPan.width,
                            height: committedPan.height + dragPan.height),
                extent: extent
            )
            let snapshot = model.orbitSnapshot(zoomProgress: metrics.zoomProgress)

            ZStack {
                ForEach(snapshot.systems) { system in
                    systemView(system, snapshot: snapshot, metrics: metrics)
                }
                driftView(snapshot, metrics: metrics)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // `position`으로 놓은 자식은 프레임을 넘어도 잘리지 않는다. 궤도는 줌인하면
            // 성계가 화면 밖까지 뻗으므로, 자르지 않으면 행성과 라벨이 위쪽 HUD 줄을
            // 침범해 스코어보드 글자 위에 겹쳐 그려진다.
            .clipped()
            .contentShape(Rectangle())
            .gesture(pan(viewport: proxy.size))
            .gesture(magnify(viewport: proxy.size, extent: extent))
            .background(theme.surfaceBase)
            .overlay(alignment: .bottomTrailing) {
                zoomControls(viewport: proxy.size, extent: extent)
            }
        }
    }

    // MARK: - 그리기

    @ViewBuilder
    private func systemView(
        _ system: OrbitSystem, snapshot: OrbitSnapshot, metrics: OrbitMetrics
    ) -> some View {
        let centre = metrics.point(system.center)

        // 등급 경계 동심원. 보드의 축 눈금이 원이 된 것이다.
        ForEach(snapshot.rings, id: \.days) { ring in
            Circle()
                .strokeBorder(theme.line, lineWidth: 0.5)
                .frame(width: metrics.length(ring.radius) * 2,
                       height: metrics.length(ring.radius) * 2)
                .position(centre)
                .opacity(0.5)
        }

        // 태양. 줌아웃에서는 같은 `Stage`의 태양들이 한 점에 모이므로 상태명을 각자
        // 그리면 글자가 포개져 읽을 수 없다. 그때는 그 무리의 첫 태양에만 `Stage`
        // 이름을 적는다 — 보드 레인이 쓰는 이름과 같은 것이라 두 화면이 이어진다.
        VStack(spacing: density.tightGap) {
            Circle()
                .fill(theme.accent)
                .frame(width: metrics.length(OrbitLayout.planetArc) * 1.4,
                       height: metrics.length(OrbitLayout.planetArc) * 1.4)
            if let label = systemLabel(system, in: snapshot, metrics: metrics) {
                Text(label)
                    .arcadeType(.readout, .xs, weight: .bold)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize()
            }
        }
        .position(centre)

        ForEach(system.planets) { planet in
            planetButton(planet, at: metrics.planetPoint(system: system, planet: planet),
                         metrics: metrics)
        }
    }

    /// 태양에 적을 이름. 갈라지기 전에는 `Stage`, 갈라진 뒤에는 실제 상태명이다.
    ///
    /// 임계를 라벨 표시(`showsPlanetLabels`, 0.5)보다 낮게 잡는 이유: 태양이 서로
    /// 떨어지기 시작하는 순간부터 상태명이 읽히는 편이 낫고, 그 시점은 티켓 키를
    /// 띄우기에는 아직 이르다.
    private func systemLabel(
        _ system: OrbitSystem, in snapshot: OrbitSnapshot, metrics: OrbitMetrics
    ) -> String? {
        guard metrics.zoomProgress <= 0.35 else { return system.statusName }
        // 뭉쳐 있는 동안에는 그 `Stage`의 첫 태양 하나만 이름을 갖는다.
        let first = snapshot.systems.first { $0.stage == system.stage }
        return first?.id == system.id ? stageLabel(system.stage) : nil
    }

    /// `BoardLaneView`가 레인 머리에 쓰는 것과 같은 이름이다. 두 화면이 같은 단계를
    /// 다르게 부르면 토글이 같은 데이터의 두 시선이라는 것이 읽히지 않는다.
    private func stageLabel(_ stage: Stage) -> String {
        switch stage {
        case .backlog: "BACKLOG"
        case .active:  "ACTIVE"
        case .review:  "REVIEW"
        case .verify:  "VERIFY"
        case .done:    "DONE"
        }
    }

    /// 어느 태양에도 속하지 못한 티켓. 성계 전체를 감싸는 바깥 고리를 떠돈다.
    /// 그냥 버리면 화면에서 조용히 사라지고 사용자는 티켓이 없어졌다고 생각한다.
    @ViewBuilder
    private func driftView(_ snapshot: OrbitSnapshot, metrics: OrbitMetrics) -> some View {
        ForEach(snapshot.drifters) { planet in
            planetButton(planet, at: metrics.driftPoint(planet), metrics: metrics)
        }
    }

    @ViewBuilder
    private func planetButton(
        _ planet: OrbitPlanet, at point: CGPoint, metrics: OrbitMetrics
    ) -> some View {
        VStack(spacing: 2) {
            PlanetView(planet: planet,
                       diameter: metrics.diameter(for: planet),
                       isPending: model.pendingTransitions[planet.id] != nil)
                .matchedGeometryEffect(id: planet.id, in: cardNamespace)
            if metrics.showsPlanetLabels {
                Text(planet.issue.key)
                    .arcadeType(.readout, .xs)
                    .foregroundStyle(theme.inkTertiary)
                    .fixedSize()
            }
        }
        .position(point)
        .onTapGesture { selected = planet.id }
        .popover(isPresented: Binding(
            get: { selected == planet.id },
            set: { if !$0 { selected = nil } }
        )) {
            PlanetPopover(planet: planet, siteHost: model.siteHost)
                // 팝오버는 환경을 물려받지 않는다. 테마와 밀도를 **함께** 다시 넣어야
                // 안팎의 글자 크기가 같아진다 — `ArcadeFloorView`의 시트가 같은 이유로
                // 같은 두 줄을 갖고 있다.
                .environment(\.arcadeTheme, theme)
                .environment(\.arcadeMetrics, density)
        }
    }

    // MARK: - 제스처

    private func clampScale(_ value: Double, viewport: CGSize, extent: Double) -> Double {
        min(max(value, OrbitMetrics.minScale(viewport: viewport, extent: extent)),
            OrbitMetrics.maxScale(viewport: viewport, extent: extent))
    }

    private func pan(viewport: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { dragPan = $0.translation }
            .onEnded { value in
                committedPan = CGSize(width: committedPan.width + value.translation.width,
                                      height: committedPan.height + value.translation.height)
                dragPan = .zero
            }
    }

    private func magnify(viewport: CGSize, extent: Double) -> some Gesture {
        MagnifyGesture()
            .onChanged { gestureScale = $0.magnification }
            .onEnded { value in
                let base = scale ?? OrbitMetrics.fitScale(viewport: viewport, extent: extent)
                scale = clampScale(base * value.magnification,
                                   viewport: viewport, extent: extent)
                gestureScale = 1
            }
    }

    /// 트랙패드가 없거나 키보드만 쓰는 경우의 경로. 궤도가 유일한 경로인 정보는
    /// 없으므로(레인이 항상 있다) 접근성 하한은 "조작 가능"이다.
    private func zoomControls(viewport: CGSize, extent: Double) -> some View {
        HStack(spacing: density.tightGap) {
            Button("−") { step(0.8, viewport: viewport, extent: extent) }
                .keyboardShortcut("-", modifiers: .command)
            Button("＋") { step(1.25, viewport: viewport, extent: extent) }
                .keyboardShortcut("=", modifiers: .command)
            Button("전체") {
                scale = nil
                committedPan = .zero
            }
            .keyboardShortcut("0", modifiers: .command)
        }
        .arcadeType(.readout, .xs)
        .padding(density.rowGap)
    }

    private func step(_ factor: Double, viewport: CGSize, extent: Double) {
        let base = scale ?? OrbitMetrics.fitScale(viewport: viewport, extent: extent)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            scale = clampScale(base * factor, viewport: viewport, extent: extent)
        }
    }
}
