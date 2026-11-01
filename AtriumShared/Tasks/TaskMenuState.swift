import AtriumProtocol
import Foundation

/// What a task's menus show and which items are enabled.
nonisolated struct TaskMenuState: Hashable, Sendable {
    var isSettled: Bool
    var isSnoozed: Bool
    var hasUnreadResult: Bool
    var supportsDeletion: Bool
    var allowed: TaskActions
    /// The other providers a fork can take the chat to, as its host enables them.
    var forkProviders: [AgentProvider] = []

    var settleAction: TaskMenuAction { isSettled ? .restore : .settle }
    /// A settled task can't be snoozed, but one that is snoozed can always wake.
    var snoozeAction: TaskMenuAction? { isSnoozed ? .unsnooze : isSettled ? nil : .snooze }
    var readAction: TaskMenuAction { hasUnreadResult ? .markRead : .markUnread }
}
