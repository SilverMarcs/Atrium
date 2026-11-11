import UserNotifications

/// Atrium in front means everything has been seen, so a device drops its
/// alerts from Notification Center, and its badge, whenever Atrium comes to
/// the front on any of them.
@MainActor
enum DeliveredNotifications {
    static func clearAll() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        Task { try? await center.setBadgeCount(0) }
    }
}
