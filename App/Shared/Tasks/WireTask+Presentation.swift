import AtriumClient
import AtriumProtocol
import Foundation

extension WireTask {
    var modelSelection: TaskModelSelection {
        TaskModelSelection(
            model: model,
            reasoningEffort: reasoningEffort,
            isFastMode: isFastMode == true,
            canSelectModel: actions.contains(.selectModel)
        )
    }

    var menuState: TaskMenuState {
        TaskMenuState(
            isSettled: isSettled,
            isSnoozed: snoozedUntil != nil,
            hasUnreadResult: hasUnreadResult,
            supportsDeletion: supportsDeletion,
            allowed: actions
        )
    }
}

extension HostTask {
    /// The task's menu state, offering forks into the host's other enabled providers.
    var menuState: TaskMenuState {
        var state = task.menuState
        state.forkProviders = host.availableProviders.filter { $0 != task.provider }
        return state
    }
}

extension TaskActions {
    func allows(_ action: TaskMenuAction) -> Bool {
        switch action {
        case .settle: contains(.settle)
        case .restore: contains(.restore)
        case .snooze: contains(.snooze)
        case .unsnooze: contains(.unsnooze)
        case .fork, .forkInto: contains(.fork)
        case .rename: contains(.rename)
        case .markRead: contains(.markRead)
        case .markUnread: contains(.markUnread)
        case .delete: contains(.delete)
        }
    }
}
