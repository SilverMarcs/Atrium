import AtriumProtocol
import Foundation

/// A task on one host. The same project can exist on several hosts, so
/// everything a client keeps across hosts is identified by host and local ID.
public nonisolated struct TaskRef: Hashable, Codable, Sendable {
    public var hostID: String
    public var taskID: String

    public init(hostID: String, taskID: String) {
        self.hostID = hostID
        self.taskID = taskID
    }
}

/// A project on one host.
public nonisolated struct WorkspaceRef: Hashable, Codable, Sendable {
    public var hostID: String
    public var workspaceID: UUID

    public init(hostID: String, workspaceID: UUID) {
        self.hostID = hostID
        self.workspaceID = workspaceID
    }
}

/// A row in a list spanning hosts: one host's task, with the host it's on.
@MainActor
public struct HostTask: Identifiable {
    public let host: HostClient
    public let task: WireTask

    public init(host: HostClient, task: WireTask) {
        self.host = host
        self.task = task
    }

    public var id: TaskRef { TaskRef(hostID: host.id, taskID: task.id) }
    public var workspace: WireWorkspace? { host.workspace(task.workspaceID) }
}
