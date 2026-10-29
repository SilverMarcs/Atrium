import Foundation

/// A new task opened on this device. The host doesn't create it until its
/// first prompt is sent, so opening one and backing out leaves nothing behind.
struct TaskDraft: Identifiable, Equatable {
    /// Stands in for the task's ID on this device; never sent to the host.
    let id = "\(Self.idPrefix)\(UUID().uuidString)"
    var workspaceID: UUID
    /// The agent the host creates the task with.
    var provider: AgentProvider
    var settings: TaskStartSettings? = nil
    /// The order it sorts in while it stands in for its task.
    let createdAt = Date.now
    /// The host is creating the task for the first prompt.
    var isCreating = false
    /// The task the host created, which the draft stands in for until the
    /// task list shows it.
    var taskID: String?

    private static let idPrefix = "draft-"

    /// Whether an ID is a draft's rather than one of the host's tasks.
    static func isDraftID(_ id: String) -> Bool {
        id.hasPrefix(idPrefix)
    }
}
