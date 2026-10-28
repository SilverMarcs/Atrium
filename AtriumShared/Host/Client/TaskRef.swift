import Foundation

/// A task on one host. The same project can exist on several hosts, so
/// everything a client keeps across hosts is identified by host and local ID.
nonisolated struct TaskRef: Hashable, Codable, Sendable {
    var hostID: String
    var taskID: String
}

/// A project on one host.
nonisolated struct WorkspaceRef: Hashable, Codable, Sendable {
    var hostID: String
    var workspaceID: UUID
}

/// A row in a list spanning hosts: one host's task, with the host it's on.
@MainActor
struct HostTask: Identifiable {
    let host: HostClient
    let task: WireTask

    var id: TaskRef { TaskRef(hostID: host.id, taskID: task.id) }
    var workspace: WireWorkspace? { host.workspace(task.workspaceID) }
}
