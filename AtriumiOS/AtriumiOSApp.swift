import SwiftUI
import UserNotifications

@main
struct AtriumiOSApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    private var client: CompanionClient { appDelegate.client }

    init() {
        UNUserNotificationCenter.current().delegate = NotificationCoordinator.shared
    }

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .environment(client)
                .task {
                    NotificationCoordinator.shared.visibleTaskID = { [client] in client.visibleTaskID }
                    NotificationCoordinator.shared.onTap = { [client] taskID in
                        client.pendingTaskID = taskID
                    }
                    client.start()
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            client.setSceneActive(phase == .active)
        }
    }
}
