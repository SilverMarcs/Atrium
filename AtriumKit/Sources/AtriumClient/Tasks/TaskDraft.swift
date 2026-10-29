import AtriumProtocol
import Foundation

/// A new task opened on this device. The host doesn't create it until its
/// first prompt is sent, so opening one and backing out leaves nothing behind.
public nonisolated struct TaskDraft: Identifiable, Equatable, Sendable {
    /// Makes asking the host to create the task again, after a lost reply,
    /// return the task it already created.
    public let key = UUID()
    public var workspaceID: UUID
    /// The agent the host creates the task with.
    public var provider: AgentProvider
    public var settings: TaskStartSettings?
    /// The order it sorts in while it stands in for its task.
    public let createdAt = Date.now
    /// The host is creating the task for the first prompt.
    public var isCreating = false
    /// The task the host created, which the draft stands in for until the
    /// task list shows it.
    public var taskID: String?

    private static let idPrefix = "draft-"

    public init(workspaceID: UUID, provider: AgentProvider, settings: TaskStartSettings? = nil) {
        self.workspaceID = workspaceID
        self.provider = provider
        self.settings = settings
    }

    /// Stands in for the task's ID on this device; never sent to the host.
    public var id: String { Self.idPrefix + key.uuidString }

    /// Whether an ID is a draft's rather than one of the host's tasks.
    public static func isDraftID(_ id: String) -> Bool {
        id.hasPrefix(idPrefix)
    }
}
