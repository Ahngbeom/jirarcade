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
final class AppActivationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 마지막 창을 닫으면 종료한다. 단일 창 앱이라 창 없이 남아 있을 이유가 없고,
    /// background-only로 되돌아간 프로세스가 유령처럼 남는 것을 막는다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        .windowResizability(.contentSize)
    }
}
