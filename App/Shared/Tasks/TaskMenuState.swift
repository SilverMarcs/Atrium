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
    var snoozeAction: TaskMenuAction? { isSnoozed ? .unsnooze : isSettled ? nil : .snooze(nil) }
    var readAction: TaskMenuAction { hasUnreadResult ? .markRead : .markUnread }

    /// The sidebar section it's listed in. Settling takes precedence, so a
    /// settled task never also counts as snoozed.
    var section: TaskSection { isSettled ? .settled : isSnoozed ? .snoozed : .active }

    /// Whether the menu offers the action and the host allows it now.
    func offers(_ action: TaskMenuAction) -> Bool {
        guard allowed.allows(action) else { return false }
        switch action {
        case .settle, .restore: return settleAction == action
        case .snooze:
            if case .snooze = snoozeAction { return true }
            return false
        case .unsnooze: return snoozeAction == action
        case .markRead, .markUnread: return readAction == action
        case .delete: return supportsDeletion
        case .fork, .forkInto, .rename: return true
        }
    }
}
