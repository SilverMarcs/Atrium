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
    /// Switches the model, and its reasoning effort when it has one, for the
    /// agent's next turns. The model is one its provider lists.
    case selectModel(id: String, reasoningEffort: String?)
    /// Turns fast mode on or off for the agent's next turns.
    case setFastMode(Bool)
    case respond(interactionID: String, decision: AgentDecision)
}
