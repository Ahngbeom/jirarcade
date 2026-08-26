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
    /// 상세 시트를 연다. 카드는 읽기 전용이라 고치려면 레인과 같은 시트로 간다.
    let onOpenDetail: (String) -> Void

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
                detailOverlay(snapshot, viewport: proxy.size)
            }
            // 트리거는 스냅샷 전체가 아니라 `membershipSignature`다 — 태양 중심은
            // `zoomProgress`에 따라서도 움직이는데, 스냅샷 전체를 걸면 확대할 때마다
            // 스프링이 걸려 손가락과 화면이 어긋난다. 소속·등급이 실제로 바뀔 때만 켠다.
            .animation(reduceMotion ? nil : .spring(duration: 0.6),
                       value: snapshot.membershipSignature)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selected)
            .frame(width: proxy.size.width, height: proxy.size.height)
            // `position`으로 놓은 자식은 프레임을 넘어도 잘리지 않는다. 궤도는 줌인하면
            // 성계가 화면 밖까지 뻗으므로, 자르지 않으면 행성과 라벨이 위쪽 HUD 줄을
            // 침범해 스코어보드 글자 위에 겹쳐 그려진다.
            .clipped()
            .contentShape(Rectangle())
            // 스크롤은 SwiftUI 제스처로 오지 않아 AppKit에서 받아 올린다. 이 층은
            // 히트 테스트를 흘려보내므로 아래의 행성 탭과 드래그 팬이 그대로 산다.
            .overlay(
                ScrollEventCatcher { delta, zooming, location in
                    handleScroll(delta, zooming: zooming, at: location, viewport: proxy.size,
                                 extent: extent, metrics: metrics)
                }
            )
            .gesture(pan(viewport: proxy.size, extent: extent))
            .gesture(magnify(viewport: proxy.size, extent: extent, snapshot: snapshot, metrics: metrics))
            .background(theme.surfaceBase)
            .overlay(alignment: .bottomTrailing) {
                zoomControls(viewport: proxy.size, extent: extent, snapshot: snapshot, metrics: metrics)
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
        // 전제가 화면에서 깨지는 지점이었다.
        PlanetView(planet: planet,
                   diameter: metrics.diameter(for: planet),
                   isPending: model.pendingTransitions[planet.id] != nil)
            .matchedGeometryEffect(id: planet.id, in: cardNamespace)
            // 티켓이 나타나고 사라지는 것도 사건이다 — 갑자기 튀어나오거나 사라지지
            // 않고 부풀거나 옅어지며 등장·소멸한다.
            .transition(.opacity.combined(with: .scale(scale: 0.3)))
            .position(point)
            .onTapGesture { select(planet.id) }

        if metrics.showsPlanetLabels {
            Text(planet.issue.key)
                .arcadeType(.readout, .xs)
                .foregroundStyle(theme.inkTertiary)
                .fixedSize()
                .transition(.opacity.combined(with: .scale(scale: 0.3)))
                .position(x: point.x, y: point.y + metrics.diameter(for: planet) / 2 + 2)
        }
    }

    /// 행성을 고른다. 미러의 값은 카드가 즉시 그리고, Jira 본문·댓글은 여기서 시작한
    /// 요청이 도착하는 대로 채운다 — 시트가 쓰는 `openDetail`과 같은 경로다.
    ///
    /// 같은 행성을 다시 누르면 다시 묻는다. 이미 받은 것을 아끼려고 건너뛰면, 그 사이
    /// 시트가 같은 슬롯(`detailState`)을 다른 티켓으로 바꿔 놓았을 때 카드가 빈 채로
    /// 남는다.
    private func select(_ id: String) {
        selected = id
        Task { await model.openDetail(issueKey: id) }
    }

    /// 카드를 닫는다. 날아가고 있던 본문·댓글 요청도 함께 끊는다 — 닫은 뒤에도 Jira에
    /// 계속 말을 걸 이유가 없다.
    private func dismissCard() {
        model.closeDetail()
        selected = nil
    }

    /// 카드에서 시트로 넘어간다. `dismissCard()`를 쓰지 **않는다** — 시트가 곧 같은
    /// 티켓을 다시 묻는데(`TicketDetailSheet.task`), 여기서 `closeDetail()`을 부르면
    /// 순서에 따라 시트의 요청이 취소된다. 시트가 열리면 그 요청이 카드의 것을
    /// 대체하고(`detailToken`), 시트가 닫힐 때 시트가 스스로 정리한다.
    private func openEditor(_ id: String) {
        selected = nil
        onOpenDetail(id)
    }

    /// 고른 행성의 상세를 궤도 위에 띄운다.
    ///
    /// `.popover`를 쓰지 않는 이유: macOS에서 팝오버는 **별도 윈도우**로 떠서 앱 창
    /// 바깥으로 나간다. 같은 뷰 트리 안에 두면 창을 벗어나지 않고, 덤으로 테마·밀도
    /// 재주입 두 줄도 필요 없어진다 — 환경이 그대로 내려오기 때문이다.
    ///
    /// 성계를 가리지 않고 살짝 어둡게만 덮는 이유는 맥락이다. "어느 행성을 눌렀는지"가
    /// 뒤에 계속 보여야 카드가 어디서 나왔는지 읽힌다.
    ///
    /// 고른 행성이 스냅샷에서 사라지면(동기화가 그 티켓을 지운 경우) 카드도 사라진다.
    /// 그때 날아가던 요청은 끊지 않는다 — 결과가 와도 `detailState`에 앉을 뿐 어느
    /// 화면도 그 키를 그리지 않고, 다음 열기가 토큰으로 대체한다.
    @ViewBuilder
    private func detailOverlay(_ snapshot: OrbitSnapshot, viewport: CGSize) -> some View {
        if let id = selected,
           let planet = (snapshot.systems.flatMap(\.planets) + snapshot.drifters)
               .first(where: { $0.id == id }) {
            ZStack {
                // 바깥을 눌러 닫는다. `contentShape`가 없으면 투명한 곳이 탭을 받지 않는다.
                theme.surfaceBase.opacity(0.72)
                    .contentShape(Rectangle())
                    .onTapGesture { dismissCard() }

                PlanetDetailCard(
                    planet: planet, model: model,
                    // 위아래로 거터만큼 남긴다 — 카드가 뷰포트에 꽉 차면 카드인지
                    // 새 화면인지 읽히지 않는다.
                    maxHeight: max(viewport.height - density.gutter * 2, 200),
                    onClose: { dismissCard() },
                    onOpenEditor: { openEditor(planet.id) }
                )
            }
            .transition(.opacity)
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
    ///
    /// 여유를 정확히 `extent`가 아니라 `extent * 1.2`로 두는 이유: 확대 앵커
    /// (`zoomAnchor`)가 화면 중심에서 가장 가까운 태양의 **중심**을 그대로 쓰는데,
    /// 태양 중심의 논리 원점 거리는 `Stage` 격자 대각선 코너 근처에서 `extent`에
    /// 근접할 수 있다. 여유 없이 `extent`로 딱 자르면 확대할 때 앵커를 화면
    /// 중심으로 옮기는 팬이 이 클램프에 걸려 잘려 나갈 수 있고, 그러면 확대-앵커
    /// 보정(`zoomPan`) 자체가 무력화된다. 1.2배는 "성계가 화면 밖으로 완전히
    /// 나가지 않을 정도면 충분하다"는 원래 클램프 목적을 지키면서 앵커에 여유를
    /// 준다. 앵커 경로만 예외로 두지 않고 여기 하나에서 여유를 주는 이유는, 그래야
    /// `body`가 매 프레임 다시 거는 클램프(아래 `pan:` 인자)가 `zoomPan`이 계산한
    /// 값을 더 좁은 기준으로 재차 잘라내는 불일치가 생기지 않기 때문이다.
    private func clampPan(_ pan: CGSize, extent: Double, scale: Double) -> CGSize {
        let bound = max(extent * scale * 1.2, 0)
        return CGSize(width: min(max(pan.width, -bound), bound),
                      height: min(max(pan.height, -bound), bound))
    }

    /// 배율이 바뀔 때 화면 중심이 가리키던 논리 좌표를 붙잡도록 `committedPan`을
    /// 다시 계산한다. **축소, 또는 화면에 태양이 하나도 없을 때**만 쓴다 — 확대는
    /// `zoomPan`이 `zoomAnchor`로 처리한다.
    ///
    /// `OrbitMetrics.point`는 `logical.x * scale + pan.width`로 화면 좌표를 만든다.
    /// 화면 중심(팬 성분 기준 0)이 가리키는 논리 좌표를 `L`이라 하면
    /// `L * scale + pan = 0` → `L = -pan / scale`이다. 배율만 `scale`에서
    /// `newScale`로 바꾸고 `pan`을 그대로 두면 같은 화면 중심이 가리키는 논리
    /// 좌표가 `-pan / newScale`로 바뀐다 — 즉 `L`이 유지되지 않는다.
    /// `L`을 유지하려면 `pan' = pan * (newScale / scale)`이어야 한다(같은 `L`을
    /// `newScale`에 대입해 풀면 나온다).
    ///
    /// 축소는 시야를 넓히는 동작이라 특정 태양으로 파고들 이유가 없다 — 지금
    /// 화면 중심이 보던 자리를 그대로 유지하는 것으로 충분하다.
    private func anchoredPan(scaleRatio: Double, extent: Double, newScale: Double) -> CGSize {
        clampPan(
            CGSize(width: committedPan.width * scaleRatio,
                  height: committedPan.height * scaleRatio),
            extent: extent, scale: newScale
        )
    }

    /// 확대할 때 붙잡을 논리 좌표 — 화면 중심에서 가장 가까운 태양의 중심이다.
    ///
    /// 화면 중심을 그대로 붙잡으면 안 되는 이유: 논리 원점(0,0)은 `Stage` 2×2
    /// 격자의 **가운데**, 곧 성계가 하나도 없는 빈 자리다. 팬하지 않은 채(또는
    /// 비례 보정만으로) 확대하면 네 성계가 원점에서 사방으로 흩어져 빈 가운데만
    /// 화면에 남는다. 이 화면에서 확대의 목적이 "한 단계를 파고들어 그 안의 상태
    /// 분화를 보는 것"이므로, 화면 중심에 가장 가까운 태양을 파고드는
    /// 목표로 삼는 것이 그 목적과 맞는다.
    private func zoomAnchor(_ snapshot: OrbitSnapshot, metrics: OrbitMetrics) -> OrbitPoint? {
        let centre = CGPoint(x: metrics.viewport.width / 2, y: metrics.viewport.height / 2)
        return snapshot.systems.min {
            squaredDistance(metrics.point($0.center), centre)
                < squaredDistance(metrics.point($1.center), centre)
        }?.center
    }

    private func squaredDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    /// 배율 변경에 맞춰 팬을 다시 계산한다 — 확대와 축소가 다른 기준을 쓴다.
    ///
    /// 확대(`factor > 1`)할 때는 화면 중심에서 가장 가까운 태양(`zoomAnchor`)을
    /// 화면 중심으로 끌어온다: `point(anchor) = viewport/2`가 되려면
    /// `anchor * newScale + pan = 0`, 곧 `pan = -anchor * newScale`이어야 한다.
    /// 축소이거나 화면에 태양이 없으면(첫 진입 등) 지금 화면 중심이 보던 논리
    /// 좌표를 그대로 유지하는 비례 보정(`anchoredPan`)을 쓴다 — 축소는 시야를
    /// 넓히는 동작이라 특정 태양으로 파고들 이유가 없고, 오히려 앵커를 옮기면
    /// 화면이 어지럽다.
    private func zoomPan(
        factor: Double, oldScale: Double, newScale: Double,
        snapshot: OrbitSnapshot, metrics: OrbitMetrics, extent: Double
    ) -> CGSize {
        guard factor > 1, let anchor = zoomAnchor(snapshot, metrics: metrics) else {
            return anchoredPan(
                scaleRatio: oldScale != 0 ? newScale / oldScale : 1,
                extent: extent, newScale: newScale
            )
        }
        return clampPan(
            CGSize(width: -anchor.x * newScale, height: -anchor.y * newScale),
            extent: extent, scale: newScale
        )
    }

    /// 스크롤 한 번을 배율이나 이동으로 옮긴다.
    ///
    /// ⌘와 함께면 확대·축소, 아니면 화면을 민다 — 지도 앱들이 쓰는 관례다. 확대·축소는
    /// **커서를 붙잡는다**: 굴리기 전 커서 아래 있던 행성이 굴린 뒤에도 커서 아래에 있다.
    /// 버튼 줌(`step`)이 쓰는 "가장 가까운 태양" 앵커를 여기서 쓰지 않는 이유는, 휠에는
    /// 버튼에 없는 정보 — 사용자가 가리키는 자리 — 가 있기 때문이다. 그 자리를 두고
    /// 다른 태양으로 끌려가면 확대할수록 보려던 것에서 멀어진다.
    private func handleScroll(
        _ delta: CGSize, zooming: Bool, at location: CGPoint, viewport: CGSize,
        extent: Double, metrics: OrbitMetrics
    ) {
        if zooming {
            // 세로 스크롤만 배율에 쓴다. 가로까지 섞으면 대각선으로 굴릴 때
            // 배율이 의도보다 크게 튄다.
            let factor = 1 + delta.height / 200
            guard factor > 0 else { return }
            let oldScale = scale ?? OrbitMetrics.fitScale(viewport: viewport, extent: extent)
            let newScale = clampScale(oldScale * factor, viewport: viewport, extent: extent)
            scale = newScale
            committedPan = cursorPan(at: location, viewport: viewport, extent: extent,
                                     oldScale: oldScale, newScale: newScale)
        } else {
            committedPan = clampPan(
                CGSize(width: committedPan.width + delta.width,
                       height: committedPan.height + delta.height),
                extent: extent, scale: metrics.scale
            )
        }
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

    /// 핀치도 휠처럼 **손이 있는 자리**를 붙잡는다. `startLocation`은 이 뷰 좌표라
    /// 휠의 `location`과 같은 좌표계다.
    private func magnify(
        viewport: CGSize, extent: Double, snapshot: OrbitSnapshot, metrics: OrbitMetrics
    ) -> some Gesture {
        MagnifyGesture()
            .onChanged { gestureScale = $0.magnification }
            .onEnded { value in
                let oldScale = scale ?? OrbitMetrics.fitScale(viewport: viewport, extent: extent)
                let newScale = clampScale(oldScale * value.magnification,
                                          viewport: viewport, extent: extent)
                scale = newScale
                committedPan = cursorPan(at: value.startLocation, viewport: viewport,
                                         extent: extent, oldScale: oldScale, newScale: newScale)
                gestureScale = 1
            }
    }

    /// 커서 아래 논리 좌표가 커서 아래에 남도록 팬을 다시 계산한다. 식은 `OrbitGeometry`에
    /// 있고 테스트가 고정한다 — 여기서는 커서를 화면-중심 기준 오프셋으로 옮기고 클램프만 건다.
    private func cursorPan(
        at location: CGPoint, viewport: CGSize, extent: Double,
        oldScale: Double, newScale: Double
    ) -> CGSize {
        let kept = OrbitGeometry.panKeepingPointUnderCursor(
            cursorOffset: (x: location.x - viewport.width / 2,
                           y: location.y - viewport.height / 2),
            pan: (x: committedPan.width, y: committedPan.height),
            oldScale: oldScale, newScale: newScale
        )
        return clampPan(CGSize(width: kept.x, height: kept.y), extent: extent, scale: newScale)
    }

    /// 트랙패드가 없거나 키보드만 쓰는 경우의 경로. 궤도가 유일한 경로인 정보는
    /// 없으므로(레인이 항상 있다) 접근성 하한은 "조작 가능"이다.
    private func zoomControls(
        viewport: CGSize, extent: Double, snapshot: OrbitSnapshot, metrics: OrbitMetrics
    ) -> some View {
        HStack(spacing: density.tightGap) {
            Button("−") {
                step(0.8, snapshot: snapshot, metrics: metrics, viewport: viewport, extent: extent)
            }
                .keyboardShortcut("-", modifiers: .command)
            Button("＋") {
                step(1.25, snapshot: snapshot, metrics: metrics, viewport: viewport, extent: extent)
            }
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

    private func step(
        _ factor: Double, snapshot: OrbitSnapshot, metrics: OrbitMetrics,
        viewport: CGSize, extent: Double
    ) {
        let oldScale = scale ?? OrbitMetrics.fitScale(viewport: viewport, extent: extent)
        let newScale = clampScale(oldScale * factor, viewport: viewport, extent: extent)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            scale = newScale
            committedPan = zoomPan(
                factor: factor, oldScale: oldScale, newScale: newScale,
                snapshot: snapshot, metrics: metrics, extent: extent
            )
        }
    }
}
