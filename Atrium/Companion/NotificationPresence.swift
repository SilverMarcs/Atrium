import Foundation

/// A companion in the foreground, and when it was last used.
struct NotificationPresence {
    let deviceID: UUID
    let taskID: String?
    var usedAt: Date
}
