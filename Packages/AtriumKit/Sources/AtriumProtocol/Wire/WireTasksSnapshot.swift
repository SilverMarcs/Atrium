import Foundation

public nonisolated struct WireTasksSnapshot: Codable, Sendable, Equatable {
    public var tasks: [WireTask]
    public var workspaces: [WireWorkspace]
    public var providers: [WireProvider]
    /// Whether the host is reloading its tasks from their providers.
    public var isRefreshing: Bool = false

    public init(tasks: [WireTask], workspaces: [WireWorkspace], providers: [WireProvider], isRefreshing: Bool = false) {
        self.tasks = tasks
        self.workspaces = workspaces
        self.providers = providers
        self.isRefreshing = isRefreshing
    }
}
