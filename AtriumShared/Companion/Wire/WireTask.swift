import Foundation

/// One row of the Mac sidebar. Sections and ordering are derived from these
/// fields on the companion with the same rules the Mac uses.
nonisolated struct WireTask: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var provider: AgentProvider
    var status: AgentThreadStatus
    var projectName: String
    /// Home-relative path of the checkout the task works in.
    var directory: String
    /// The Atrium project the task belongs to, when one exists on the Mac.
    var workspaceID: UUID?
    var updatedAt: Date
    var hasUnreadResult: Bool
    var isSettled: Bool
    var snoozedUntil: Date?
    var supportsDeletion: Bool
    /// Actions the Mac currently allows, so the companion never offers one it would reject.
    var actions: TaskActions
    /// The model the agent last ran with and its reasoning effort, when known.
    var model: String?
    var reasoningEffort: String?
    /// Whether the agent runs in fast mode, when its provider has one and it's known.
    var isFastMode: Bool?
    /// Optional for compatibility with hosts predating native agent decisions.
    var interactions: [AgentInteraction]? = nil

    var isSnoozed: Bool { snoozedUntil != nil && !isSettled }

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

    static func newestFirst(_ lhs: WireTask, _ rhs: WireTask) -> Bool {
        lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt > rhs.updatedAt
    }
}
