import SwiftUI
import UserNotifications

@main
struct AtriumiOSApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    private var hosts: HostDirectory { appDelegate.hosts }

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .environment(hosts)
                .onOpenURL(prefersInApp: true)
                .task {
                    hosts.start()
                    #if DEBUG
                    await hosts.applyDebugLaunch()
                    #endif
                }
                .task(id: hosts.hosts.isEmpty) {
                    // Asks once to show alerts, then registers with APNs, which
                    // answers through the app delegate on every launch. A local
                    // development relay can't deliver pushes.
                    #if DEBUG
                    guard ProcessInfo.processInfo.environment["ATRIUM_RELAY_URL"] == nil else { return }
                    #endif
                    guard !hosts.hosts.isEmpty,
                          (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
                    UIApplication.shared.registerForRemoteNotifications()
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            hosts.setActive(phase == .active)
        }
    }
}
