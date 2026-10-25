import Foundation

/// An action offered on a task in the sidebar's menus and swipe actions.
nonisolated enum TaskMenuAction: Hashable, Sendable {
    case settle
    case restore
    case snooze
    case unsnooze
    case fork
    case rename
    case markRead
    case markUnread
    case delete
}
