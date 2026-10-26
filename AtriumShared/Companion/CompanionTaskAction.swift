import Foundation

nonisolated enum CompanionTaskAction: Codable, Sendable {
    case settle
    case restore
    case snooze(until: Date)
    case unsnooze
    /// Acknowledges the result locally, just like opening the task on the host.
    case viewed
    case markRead
    case markUnread
    case rename(title: String)
    case fork
    case delete
}
