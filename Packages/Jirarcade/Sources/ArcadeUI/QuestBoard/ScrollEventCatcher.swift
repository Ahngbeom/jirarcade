import SwiftUI
import AppKit

/// 스크롤 휠과 트랙패드 두 손가락 스크롤을 SwiftUI로 올려 준다.
///
/// **왜 AppKit으로 내려가는가:** SwiftUI는 이 이벤트를 제스처로 노출하지 않는다.
/// `DragGesture`는 눌린 채 끄는 것만 받고, `MagnifyGesture`는 핀치만 받는다. 스크롤은
/// 둘 중 어느 쪽도 아니어서, 궤도 화면에서 마우스 휠을 굴려도 아무 일이 없었다.
///
/// **왜 `scrollWheel(with:)`를 override하지 않고 이벤트 모니터를 쓰는가:** 이 뷰는
/// 행성 탭과 드래그 팬 위에 덮여 있어 `hitTest`가 nil이어야 한다 — 아니면 그 둘이 죽는다.
/// 그런데 AppKit은 스크롤 이벤트도 `hitTest`로 찾은 "커서 아래 뷰"에 보내므로, `hitTest`가
/// nil인 뷰는 `scrollWheel(with:)`를 **한 번도 받지 못한다.** 예전 구현이 정확히 그
/// 상태였다: 휠을 굴려도 확대도 이동도 되지 않았다. 로컬 모니터는 히트 테스트와 무관하게
/// 이 창의 모든 스크롤 이벤트를 보므로, 이 뷰의 영역 안에서 일어난 것만 골라 올린다.
///
/// **경계를 좁게 잡는다.** 이 뷰가 아는 것은 "얼마나 굴렸고, ⌘가 눌렸고, 어디서 굴렸나"
/// 뿐이다. 그 값으로 무엇을 할지 — 배율을 바꿀지 화면을 밀지, 얼마나 바꿀지 — 는 전부
/// `OrbitView`에 남는다. 이 저장소의 첫 AppKit 하강이므로, 나중에 SwiftUI가 스크롤을
/// 제스처로 열어 주면 이 파일만 지우면 되게 해 둔다.
struct ScrollEventCatcher: NSViewRepresentable {
    /// - Parameters:
    ///   - delta: 이번 이벤트의 스크롤 양. 위/오른쪽이 양수다.
    ///   - zooming: ⌘가 함께 눌렸는가. 눌렸으면 확대·축소, 아니면 이동이다.
    ///   - location: 커서 위치. 이 뷰의 좌표계이고 SwiftUI처럼 **왼쪽 위가 원점**이다.
    ///     확대가 커서를 붙잡는 데 쓴다.
    let onScroll: (_ delta: CGSize, _ zooming: Bool, _ location: CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        // 클로저는 매 렌더 새로 만들어진다. 갱신하지 않으면 첫 렌더의 클로저가 그대로
        // 남아, 그 안에 갇힌 `scale`·`committedPan`이 영영 초기값으로 계산된다.
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGSize, Bool, CGPoint) -> Void)?
        private var monitor: Any?

        /// 클릭은 아래로 흘려보낸다. 이 뷰는 행성 탭과 드래그 팬 위에 덮여 있으므로,
        /// 여기서 히트 테스트를 받으면 그 둘이 전부 죽는다. (스크롤을 못 받게 되는 대가는
        /// 위의 이벤트 모니터가 치른다.)
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// 창에 붙을 때 걸고 떨어질 때 푼다. `deinit`만 믿으면 안 된다 — 모니터 클로저가
        /// `self`를 약하게 잡아도 모니터 자체는 창이 바뀔 때 새로 걸어야 한다.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                // 처리한 이벤트는 여기서 끝낸다. 흘려보내면 SwiftUI 호스팅 뷰가 받아
                // 응답자 체인을 타고 올라가는데, 궤도 화면에는 그것을 받을 스크롤 뷰가
                // 없으니 해는 없지만 뜻도 없다.
                return nil
            }
        }

        deinit { removeMonitor() }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// 이 창, 이 뷰 안에서 일어난 스크롤인가. 맞으면 올리고 true를 돌려준다.
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            // AppKit 좌표는 왼쪽 **아래**가 원점이다. 이 뷰 좌표로 바꾼 뒤 y를 뒤집어
            // SwiftUI와 같은 왼쪽 위 원점으로 맞춘다 — `OrbitMetrics.point`가 그 좌표계다.
            let local = convert(event.locationInWindow, from: nil)
            guard bounds.contains(local) else { return false }
            let location = CGPoint(x: local.x, y: bounds.height - local.y)

            // `hasPreciseScrollingDeltas`는 트랙패드와 마우스 휠을 가른다. 휠은 한 칸에
            // ±1 남짓을 주고 트랙패드는 훨씬 잘게 나눠 주므로, 같은 배율로 다루면
            // 휠에서는 거의 움직이지 않고 트랙패드에서는 튄다.
            let step = event.hasPreciseScrollingDeltas ? 1.0 : 8.0
            let delta = CGSize(width: event.scrollingDeltaX * step,
                               height: event.scrollingDeltaY * step)
            guard delta.width != 0 || delta.height != 0 else { return false }
            onScroll?(delta, event.modifierFlags.contains(.command), location)
            return true
        }
    }
}
