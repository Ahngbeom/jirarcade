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
            let clampedScale = clampScale(base * gestureScale, viewport: proxy.size, extent: extent)
            let metrics = OrbitMetrics(
                viewport: proxy.size,
                scale: clampedScale,
                // 클램프는 `metrics.pan`을 만드는 이 자리에서 매 프레임 건다 — 드래그가
                // 진행 중이든 끝났든 화면에 나가는 값은 항상 상한 안에 있다.
                pan: clampPan(
                    CGSize(width: committedPan.width + dragPan.width,
                           height: committedPan.height + dragPan.height),
                    extent: extent, scale: clampedScale
                ),
                extent: extent
            )
            let snapshot = model.orbitSnapshot(zoomProgress: metrics.zoomProgress)

            ZStack {
                ForEach(snapshot.systems) { system in
                    systemView(system, snapshot: snapshot, metrics: metrics)
                }
                driftView(snapshot, metrics: metrics)
            }
            // 트리거는 스냅샷 전체가 아니라 `membershipSignature`다 — 태양 중심은
            // `zoomProgress`에 따라서도 움직이는데, 스냅샷 전체를 걸면 확대할 때마다
            // 스프링이 걸려 손가락과 화면이 어긋난다. 소속·등급이 실제로 바뀔 때만 켠다.
            .animation(reduceMotion ? nil : .spring(duration: 0.6),
                       value: snapshot.membershipSignature)
            .frame(width: proxy.size.width, height: proxy.size.height)
            // `position`으로 놓은 자식은 프레임을 넘어도 잘리지 않는다. 궤도는 줌인하면
            // 성계가 화면 밖까지 뻗으므로, 자르지 않으면 행성과 라벨이 위쪽 HUD 줄을
            // 침범해 스코어보드 글자 위에 겹쳐 그려진다.
            .clipped()
            .contentShape(Rectangle())
            .gesture(pan(viewport: proxy.size, extent: extent))
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
        //
        // 원과 라벨을 **각각** `.position`으로 놓는다 — `VStack { 원; 라벨 }.position(centre)`로
        // 묶으면 `.position`이 VStack 전체의 중심을 centre에 맞추므로, 원 자체의 중심은
        // centre에서 라벨 절반 높이 + 간격만큼 위로 밀린다. 기본 배율에서 그 어긋남이
        // 태양 반지름(약 4.7pt)보다 크다. 그런데 행성은 `system.center`(=centre)를
        // 중심으로 도므로, 태양이 자기 궤도 중심에 있지 않게 된다.
        Circle()
            .fill(theme.accent)
            .frame(width: metrics.length(OrbitLayout.planetArc) * 1.4,
                   height: metrics.length(OrbitLayout.planetArc) * 1.4)
            .position(centre)

        if let label = systemLabel(system, in: snapshot, metrics: metrics) {
            // 최소 궤도(`OrbitLayout.minimumRadius`) 바깥에 놓는다 — 그 안쪽에 두면
            // 궤도선과 가장 안쪽 행성이 라벨 위로 그려진다.
            Text(label)
                .arcadeType(.readout, .xs, weight: .bold)
                .foregroundStyle(theme.inkSecondary)
                .fixedSize()
                .position(x: centre.x,
                          y: centre.y + metrics.length(OrbitLayout.minimumRadius) + density.tightGap)
        }

        // 뷰포트 밖 행성은 그리지 않는다(컬링). `.clipped()`는 그리기만 자르고 히트
        // 영역은 남기므로, 그리지 않은 행성은 보이지 않는 채로 탭을 가로채는 일도
        // 함께 사라진다 — 줌인했을 때 화면 밖 행성이 HUD의 스코어보드·보기 토글
        // 위를 덮어 클릭을 먹던 원인이 이것이다.
        ForEach(visiblePlanets(system.planets, in: system, metrics: metrics), id: \.planet.id) { entry in
            planetButton(entry.planet, at: entry.point, metrics: metrics)
        }
    }

    /// 성계 소속 행성 중 뷰포트 안에 걸치는 것만 좌표와 함께 돌려준다. 좌표를 한 번만
    /// 계산해 컬링 판정과 실제 그리기에 같이 쓴다.
    private func visiblePlanets(
        _ planets: [OrbitPlanet], in system: OrbitSystem, metrics: OrbitMetrics
    ) -> [(planet: OrbitPlanet, point: CGPoint)] {
        planets.compactMap { planet in
            let point = metrics.planetPoint(system: system, planet: planet)
            guard metrics.isVisible(point, diameter: metrics.diameter(for: planet)) else { return nil }
            return (planet, point)
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
        // 궤도 태양과 보드 레인이 같은 단계를 다르게 부르면 토글이 같은 데이터의
        // 두 시선이라는 것이 읽히지 않는다 — `BoardLaneView`와 같은 곳(`TicketPresentation`)에서 받는다.
        return first?.id == system.id ? TicketPresentation.stageLabel(system.stage) : nil
    }

    /// 어느 태양에도 속하지 못한 티켓. 성계 전체를 감싸는 바깥 고리를 떠돈다.
    /// 그냥 버리면 화면에서 조용히 사라지고 사용자는 티켓이 없어졌다고 생각한다.
    /// 뷰포트 밖 떠돌이도 성계 행성과 같은 이유로 걸러낸다(컬링, 수정 2).
    @ViewBuilder
    private func driftView(_ snapshot: OrbitSnapshot, metrics: OrbitMetrics) -> some View {
        let visible = snapshot.drifters.compactMap { planet -> (planet: OrbitPlanet, point: CGPoint)? in
            let point = metrics.driftPoint(planet)
            guard metrics.isVisible(point, diameter: metrics.diameter(for: planet)) else { return nil }
            return (planet, point)
        }
        ForEach(visible, id: \.planet.id) { entry in
            planetButton(entry.planet, at: entry.point, metrics: metrics)
        }
    }

    @ViewBuilder
    private func planetButton(
        _ planet: OrbitPlanet, at point: CGPoint, metrics: OrbitMetrics
    ) -> some View {
        // 행성과 티켓 키 라벨을 **각각** `.position`으로 놓는다. 태양과 같은 이유다
        // (systemView 주석 참고) — `VStack { 행성; 라벨 }.position(point)`로 묶으면
        // `zoomProgress`가 0.5를 넘어 라벨이 붙는 순간 VStack의 중심 계산이 바뀌어
        // 모든 행성이 위로 점프한다. "줌은 좌표를 바꾸지 않는다"는 이 화면의 설계
        // 전제(§4)가 화면에서 깨지는 지점이었다.
        PlanetView(planet: planet,
                   diameter: metrics.diameter(for: planet),
                   isPending: model.pendingTransitions[planet.id] != nil)
            .matchedGeometryEffect(id: planet.id, in: cardNamespace)
            // 티켓이 나타나고 사라지는 것도 사건이다 — 갑자기 튀어나오거나 사라지지
            // 않고 부풀거나 옅어지며 등장·소멸한다.
            .transition(.opacity.combined(with: .scale(scale: 0.3)))
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

        if metrics.showsPlanetLabels {
            Text(planet.issue.key)
                .arcadeType(.readout, .xs)
                .foregroundStyle(theme.inkTertiary)
                .fixedSize()
                .transition(.opacity.combined(with: .scale(scale: 0.3)))
                .position(x: point.x, y: point.y + metrics.diameter(for: planet) / 2 + 2)
        }
    }

    // MARK: - 제스처

    private func clampScale(_ value: Double, viewport: CGSize, extent: Double) -> Double {
        min(max(value, OrbitMetrics.minScale(viewport: viewport, extent: extent)),
            OrbitMetrics.maxScale(viewport: viewport, extent: extent))
    }

    /// 성계 전체(논리 반지름 `extent`)가 화면 밖으로 완전히 밀려나지 않도록 팬을
    /// pt로 환산한 `extent` 안으로 가둔다. 클램프가 없으면 드래그만으로 성계 중심을
    /// 화면 밖으로 끌어낼 수 있고, 되돌아오는 유일한 길이 ⌘0(전체) 리셋뿐이게 된다.
    private func clampPan(_ pan: CGSize, extent: Double, scale: Double) -> CGSize {
        let bound = max(extent * scale, 0)
        return CGSize(width: min(max(pan.width, -bound), bound),
                      height: min(max(pan.height, -bound), bound))
    }

    private func pan(viewport: CGSize, extent: Double) -> some Gesture {
        DragGesture()
            .onChanged { dragPan = $0.translation }
            .onEnded { value in
                let base = scale ?? OrbitMetrics.fitScale(viewport: viewport, extent: extent)
                committedPan = clampPan(
                    CGSize(width: committedPan.width + value.translation.width,
                          height: committedPan.height + value.translation.height),
                    extent: extent, scale: base
                )
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
                // 팬·줌 상태 넷을 모두 되돌린다. `gestureScale`·`dragPan`은 제스처가
                // `onEnded` 없이 취소되면 1·0이 아닌 값으로 굳을 수 있는데, `scale`과
                // `committedPan`만 초기화하면 그 굳은 값이 새 배율·팬과 다시 섞여
                // 화면이 복구되지 않는다. "전체"가 유일한 복구 경로이므로 넷 다 지운다.
                scale = nil
                committedPan = .zero
                dragPan = .zero
                gestureScale = 1
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
