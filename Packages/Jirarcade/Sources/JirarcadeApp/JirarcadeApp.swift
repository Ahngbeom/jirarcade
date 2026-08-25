import SwiftUI
import AppKit
import ArcadeApp
import ArcadeCore
import JiraKit
import ArcadeUI

/// 이 앱을 `.app` 번들 없이 실행할 때(예: `swift run JirarcadeApp`) macOS Launch Services는
/// 프로세스를 **background-only**로 등록한다. 그러면 창은 그려지지만 key window가 되지 못해
/// 클릭·타이핑·⌘C/⌘V가 전부 먹지 않는다 — 화면은 정상으로 보이는데 아무것도 입력할 수 없다.
///
/// 활성화 정책을 명시적으로 `.regular`로 올려 어떤 실행 방식에서도 전경 앱이 되게 한다.
/// `.app` 번들로 실행하면 이미 `.regular`이므로 이 호출은 무해하다.
@MainActor
final class AppActivationDelegate: NSObject, NSApplicationDelegate {
    /// 창 레이아웃을 크게 바꿀 때 올린다. 저장된 값이 이보다 작으면 창을 한 번만
    /// 새 기본 크기로 다시 잡는다.
    private static let layoutGeneration = 2
    private static let layoutGenerationKey = "windowLayoutGeneration"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        armWindowResizeIfLayoutChanged()
    }

    /// 마지막 창을 닫으면 종료한다. 단일 창 앱이라 창 없이 남아 있을 이유가 없고,
    /// background-only로 되돌아간 프로세스가 유령처럼 남는 것을 막는다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 레이아웃을 크게 바꾼 뒤 **첫 실행에서 한 번만** 창을 새 기본 크기로 다시 잡는다.
    ///
    /// SwiftUI는 창 크기·위치를 루트 뷰 타입 이름으로 autosave하고(실측 키:
    /// `NSWindow Frame ArcadeUI.RootView-1-AppWindow-1`), 저장된 프레임이 있으면
    /// `.defaultSize`를 **무시한다**. 그래서 이 앱을 이미 써 온 사용자는 넓은 화면
    /// 기준으로 레이아웃을 개편해도 예전 크기(새 최소 크기로 클램프된 값) 그대로 열려,
    /// 새 레이아웃이 한 번도 제 모습으로 보이지 않는다.
    ///
    /// 한 번 손댄 뒤 세대 번호를 저장해 다시 끼어들지 않는다. 그 뒤 사용자가 조절한
    /// 크기는 macOS가 평소처럼 기억한다.
    private func armWindowResizeIfLayoutChanged() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.layoutGenerationKey) < Self.layoutGeneration
        else { return }

        // 창은 SwiftUI가 이 시점 **이후에** 만든다. 여기서 `NSApp.windows`를 뒤지면 아직
        // 비어 있으므로, 첫 창이 key가 되는 순간을 기다린다.
        //
        // 블록 기반 옵저버가 아니라 셀렉터 기반을 쓰는 이유: 블록은 `@Sendable`이라
        // `Notification`(과 그 안의 `NSWindow`)을 클로저 안으로 나를 수 없고, 우회로
        // `NSApp.keyWindow`를 읽으면 **알림 시점에는 아직 nil**이라 아무 일도 일어나지
        // 않는다(실측). 셀렉터는 알림을 올린 스레드에서 그대로 불려 창을 직접 받는다.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(firstWindowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func firstWindowBecameKey(_ notification: Notification) {
        // 시트·패널이 아니라 본 창일 때만 손댄다.
        guard let window = notification.object as? NSWindow, window.canBecomeMain else { return }
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didBecomeKeyNotification, object: nil
        )
        UserDefaults.standard.set(Self.layoutGeneration, forKey: Self.layoutGenerationKey)
        resetToDefaultSize(window)
    }

    private func resetToDefaultSize(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        // 제목 표시줄을 뺀 **콘텐츠** 영역으로 환산해 비교한다. 프레임끼리 비교하면
        // 제목 표시줄 높이만큼 창이 작업 영역을 넘어간다.
        let room = window.contentRect(forFrameRect: screen.visibleFrame).size
        let fitted = LayoutTokens.fittedWindow(
            within: LayoutTokens.WindowSize(width: room.width, height: room.height)
        )
        window.setContentSize(NSSize(width: fitted.width, height: fitted.height))
        // 크기만 바꾸면 원점이 왼쪽 아래에 고정돼 창이 화면 밖으로 밀려날 수 있다.
        window.center()
    }
}

@main
struct JirarcadeApp: App {
    @NSApplicationDelegateAdaptor(AppActivationDelegate.self) private var activation
    @State private var model: AppModel

    init() {
        let store: ArcadeStore
        do {
            store = ArcadeStore(container: try ArcadeStore.makePersistentContainer())
        } catch {
            fatalError("저장소를 열 수 없습니다: \(error)")
        }
        let workflow: any WorkflowStore
        do {
            workflow = try FileWorkflowStore.applicationSupport()
        } catch {
            fatalError("설정 디렉터리를 만들 수 없습니다: \(error)")
        }

        _model = State(initialValue: AppModel(
            store: store,
            credentials: KeychainCredentialStore(),
            workflow: workflow,
            accountBinding: UserDefaultsAccountBindingStore(),
            sprintField: {
                do { return try FileSprintFieldStore.applicationSupport() }
                catch {
                    // 설정 디렉터리를 못 열면 워크플로 저장소도 이미 실패했을 것이다.
                    // 여기서 앱을 죽이지 않고 메모리 저장소로 degrade한다 — 이월 표시는
                    // 이번 실행에서만 빠지고 다음 실행에서 다시 시도한다.
                    return InMemorySprintFieldStore()
                }
            }(),
            clientFactory: { auth in JiraClient(auth: auth, http: URLSessionHTTPClient()) },
            clock: { Date() },
            calendar: .current
        ))
    }

    var body: some Scene {
        WindowGroup("Jirarcade") {
            RootView(model: model)
        }
        // 첫 실행에서만 쓰이는 크기다 — 사용자가 창을 조절하면 macOS가 그 크기를 기억한다.
        .defaultSize(width: LayoutTokens.defaultWindow.width,
                     height: LayoutTokens.defaultWindow.height)
        // `.contentSize`는 창을 **콘텐츠 크기에 맞춰** 잡는다. 그러면 RootView의 최소
        // 프레임이 곧 실행 크기가 되어, 1920×1080 디스플레이에서도 앱이 최소 크기로
        // 열리고 `.defaultSize`는 무시된다. `.contentMinSize`는 최소만 강제하고 나머지는
        // 창에 맡긴다 — 사용자가 자유롭게 늘릴 수 있어야 넓은 밀도가 실제로 쓰인다.
        .windowResizability(.contentMinSize)
    }
}
