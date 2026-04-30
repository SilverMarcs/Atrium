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
                    // Capture the (long-lived) client instance so the
                    // notification coordinator can hand the tap straight
                    // to the router via `pendingDeepLink`.
                    NotificationCoordinator.shared.onTap = { [client] wsId, sid in
                        client.pendingDeepLink = PendingDeepLink(
                            workspaceId: wsId,
                            sessionId: sid
                        )
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                client.handleScenePhaseActive()
            }
        }
    }
}
