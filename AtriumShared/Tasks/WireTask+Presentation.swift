import AtriumProtocol
import Foundation

extension WireTask {
    /// The model and reasoning effort as one line, such as "gpt-6.1 · High".
    var modelSummary: String? { modelSummary(using: []) }

    /// The model and reasoning effort as one line, with the model named as its
    /// provider lists it, such as "Opus 5.5 · High", and "Fast" in fast mode.
    func modelSummary(using models: [AgentModel]) -> String? {
        modelSelection.summary(using: models)
    }

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

extension TaskActions {
    func allows(_ action: TaskMenuAction) -> Bool {
        switch action {
        case .settle: contains(.settle)
        case .restore: contains(.restore)
        case .snooze: contains(.snooze)
        case .unsnooze: contains(.unsnooze)
        case .fork: contains(.fork)
        case .rename: contains(.rename)
        case .markRead: contains(.markRead)
        case .markUnread: contains(.markUnread)
        case .delete: contains(.delete)
        }
    }
}
