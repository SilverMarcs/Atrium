import SwiftUI
import UserNotifications

@main
struct AtriumiOSApp: App {
    @State private var client = CompanionClient()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationCoordinator.shared
    }

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .environment(client)
                .task {
                    NotificationCoordinator.shared.onTap = { [client] taskID in
                        client.pendingTaskID = taskID
                    }
                    client.start()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { client.sceneDidBecomeActive() }
        }
    }
}
