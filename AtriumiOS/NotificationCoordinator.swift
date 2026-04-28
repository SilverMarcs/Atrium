import Foundation
import UserNotifications

/// Lets locally-scheduled notifications surface as banners + sound while
/// the iOS app is in the foreground, and forwards taps onto a callback
/// the app wires to navigation. Without the foreground delegate, iOS
/// suppresses the alert whenever the user happens to be in the app.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()

    /// Called on the main actor when the user taps a finished-session
    /// notification. Set by `AtriumiOSApp` to push that chat onto the
    /// nav stack.
    var onTap: ((UUID, UUID) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard
            let wsString = info["workspaceId"] as? String,
            let sidString = info["sessionId"] as? String,
            let workspaceId = UUID(uuidString: wsString),
            let sessionId = UUID(uuidString: sidString)
        else { return }
        onTap?(workspaceId, sessionId)
    }
}
