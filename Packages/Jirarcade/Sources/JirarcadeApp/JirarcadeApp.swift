import SwiftUI
import ArcadeApp
import ArcadeCore
import JiraKit
import ArcadeUI

@main
struct JirarcadeApp: App {
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
