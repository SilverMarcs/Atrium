import SwiftUI

@main
struct AtriumiOSApp: App {
    @State private var client = CompanionClient()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .environment(client)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                client.handleScenePhaseActive()
            }
        }
    }
}
