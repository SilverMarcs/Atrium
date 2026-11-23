import Foundation

/// Whether a client is in the foreground and which of this host's tasks it
/// shows. Sent only when either changes; the host decides from it which device
/// gets alerts and which task counts as read while it's on screen.
public nonisolated struct ClientActivity: Codable, Sendable, Equatable {
    public var isActive: Bool
    public var taskID: String?

    public init(isActive: Bool, taskID: String? = nil) {
        self.isActive = isActive
        self.taskID = taskID
    }
}
