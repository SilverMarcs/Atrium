import UIKit

/// Receives the APNs device token, which only the application delegate is told.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let client = CompanionClient()

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        client.didRegisterForPush(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        print("Couldn’t register for push notifications: \(error.localizedDescription)")
    }
}
