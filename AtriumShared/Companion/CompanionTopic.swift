import Foundation

/// State a client wants pushed to it. Subscribing sends a full snapshot; the
/// server then sends changes until the client unsubscribes or disconnects.
nonisolated enum CompanionTopic: Codable, Sendable, Hashable {
    case tasks
    case git(workspaceID: UUID)
    case commands(workspaceID: UUID)
}
