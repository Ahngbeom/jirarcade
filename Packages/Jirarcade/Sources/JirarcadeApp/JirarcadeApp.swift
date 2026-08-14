import SwiftUI

@main
struct JirarcadeApp: App {
    var body: some Scene {
        WindowGroup("Jirarcade") {
            Text("Jirarcade")
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowResizability(.contentSize)
    }
}
