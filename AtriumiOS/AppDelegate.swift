import UIKit
import UserNotifications

/// Receives the APNs device token, which only the application delegate is told.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let client = CompanionClient()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationCoordinator.shared.client = client
        UNUserNotificationCenter.current().delegate = NotificationCoordinator.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        client.didRegisterForPush(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        print("Couldn’t register for push notifications: \(error.localizedDescription)")
    }
}
