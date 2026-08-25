import SwiftUI
import AppKit

/// 스크롤 휠과 트랙패드 두 손가락 스크롤을 SwiftUI로 올려 준다.
///
/// **왜 AppKit으로 내려가는가:** SwiftUI는 이 이벤트를 제스처로 노출하지 않는다.
/// `DragGesture`는 눌린 채 끄는 것만 받고, `MagnifyGesture`는 핀치만 받는다. 스크롤은
/// 둘 중 어느 쪽도 아니어서, 궤도 화면에서 마우스 휠을 굴려도 아무 일이 없었다.
///
/// **경계를 좁게 잡는다.** 이 뷰가 아는 것은 "얼마나 굴렸고 ⌘가 눌렸나"뿐이다.
/// 그 값으로 무엇을 할지 — 배율을 바꿀지 화면을 밀지, 얼마나 바꿀지 — 는 전부
/// `OrbitView`에 남는다. 이 저장소의 첫 AppKit 하강이므로, 나중에 SwiftUI가 스크롤을
/// 제스처로 열어 주면 이 파일만 지우면 되게 해 둔다.
struct ScrollEventCatcher: NSViewRepresentable {
    /// - Parameters:
    ///   - delta: 이번 이벤트의 스크롤 양. 위/오른쪽이 양수다.
    ///   - zooming: ⌘가 함께 눌렸는가. 눌렸으면 확대·축소, 아니면 이동이다.
    let onScroll: (_ delta: CGSize, _ zooming: Bool) -> Void

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
        var onScroll: ((CGSize, Bool) -> Void)?

        /// 클릭은 아래로 흘려보낸다. 이 뷰는 행성 탭과 드래그 팬 위에 덮여 있으므로,
        /// 여기서 히트 테스트를 받으면 그 둘이 전부 죽는다.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func scrollWheel(with event: NSEvent) {
            // `hasPreciseScrollingDeltas`는 트랙패드와 마우스 휠을 가른다. 휠은 한 칸에
            // ±1 남짓을 주고 트랙패드는 훨씬 잘게 나눠 주므로, 같은 배율로 다루면
            // 휠에서는 거의 움직이지 않고 트랙패드에서는 튄다.
            let step = event.hasPreciseScrollingDeltas ? 1.0 : 8.0
            let delta = CGSize(width: event.scrollingDeltaX * step,
                               height: event.scrollingDeltaY * step)
            guard delta.width != 0 || delta.height != 0 else { return }
            onScroll?(delta, event.modifierFlags.contains(.command))
        }
    }
}
