import AtriumProtocol
import UIKit
import UserNotifications

/// Receives the APNs device token, which only the application delegate is told.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let hosts = HostDirectory()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationCoordinator.shared.hosts = hosts
        UNUserNotificationCenter.current().delegate = NotificationCoordinator.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        #if DEBUG
        let environment = PushRegistration.Environment.sandbox
        #else
        let environment = PushRegistration.Environment.production
        #endif
        hosts.didRegisterForPush(PushRegistration(
            token: deviceToken.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined(),
            environment: environment
        ))
    }

    /// Atrium came to the front on another device, whose push already cleared
    /// the badge, so the alerts it has seen leave Notification Center too.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard userInfo["clear"] as? Bool == true else { return .noData }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        return .noData
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        print("Couldn’t register for push notifications: \(error.localizedDescription)")
    }
}
