import Foundation
import UserNotifications

/// Routes taps immediately, including during launch before views are installed.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()

    weak var client: CompanionClient?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        if let hostID = info["hostID"] as? String,
           hostID == client?.currentHost?.id,
           let taskID = info["taskID"] as? String,
           taskID == client?.visibleTaskID { return [] }
        return [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let taskID = info["taskID"] as? String else { return }
        client?.openNotification(hostID: info["hostID"] as? String, taskID: taskID)
    }
}
