import AtriumProtocol
import Foundation

/// An action offered on a task in the sidebar's menus and swipe actions.
nonisolated enum TaskMenuAction: Hashable, Sendable {
    case settle
    case restore
    case snooze
    case unsnooze
    /// Forks the chat with its own provider.
    case fork
    /// Forks the chat into another provider, which takes over its conversation.
    case forkInto(AgentProvider)
    case rename
    case markRead
    case markUnread
    case delete
}
