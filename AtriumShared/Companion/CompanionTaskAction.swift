import Foundation

nonisolated enum CompanionTaskAction: Codable, Sendable {
    case settle
    case restore
    case snooze(until: Date)
    case unsnooze
    case markRead
    case markUnread
    case rename(title: String)
    case fork
    case delete
}
