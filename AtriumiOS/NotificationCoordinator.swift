import Foundation
import UserNotifications

/// Routes taps immediately, including during launch before views are installed.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()

    weak var hosts: HostDirectory?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        if let hostID = info["hostID"] as? String, let taskID = info["taskID"] as? String,
           hosts?.isShowing(TaskRef(hostID: hostID, taskID: taskID)) == true { return [] }
        return [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let hostID = info["hostID"] as? String, let taskID = info["taskID"] as? String else { return }
        hosts?.openNotification(hostID: hostID, taskID: taskID)
    }
}
