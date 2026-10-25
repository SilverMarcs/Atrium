import Foundation

nonisolated enum CompanionEvent: Codable, Sendable {
    /// The first message on every connection, before authentication.
    case hello(hostName: String, protocolVersion: Int)
    case tasks(WireTasksSnapshot)
    case tasksChanged(WireTasksDelta)
    case git(workspaceID: UUID, status: WireGitStatus)
    case commands(workspaceID: UUID, commands: [WireCommand])
}
