import Foundation

nonisolated struct WireTasksSnapshot: Codable, Sendable, Equatable {
    var tasks: [WireTask]
    var workspaces: [WireWorkspace]
    var providers: [WireProvider]
    /// Whether the host is reloading its tasks from their providers.
    var isRefreshing = false
}
