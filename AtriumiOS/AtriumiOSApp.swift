import SwiftUI
import UserNotifications

@main
struct AtriumiOSApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    private var client: CompanionClient { appDelegate.client }

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .environment(client)
                .task {
                    client.start()
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            client.setSceneActive(phase == .active)
        }
    }
}
