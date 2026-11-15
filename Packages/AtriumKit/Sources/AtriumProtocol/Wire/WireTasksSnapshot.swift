import Foundation

public nonisolated struct WireTasksSnapshot: Codable, Sendable, Equatable {
    public var tasks: [WireTask]
    public var workspaces: [WireWorkspace]
    public var providers: [WireProvider]
    /// Whether the host is reloading its tasks from their providers.
    public var isRefreshing: Bool = false

    private enum CodingKeys: String, CodingKey {
        case tasks, workspaces, providers, isRefreshing
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decode(ProviderRows<WireTask>.self, forKey: .tasks).values
        workspaces = try container.decode([WireWorkspace].self, forKey: .workspaces)
        providers = try container.decode(ProviderRows<WireProvider>.self, forKey: .providers).values
        isRefreshing = try container.decodeIfPresent(Bool.self, forKey: .isRefreshing) ?? false
    }

    public init(tasks: [WireTask], workspaces: [WireWorkspace], providers: [WireProvider], isRefreshing: Bool = false) {
        self.tasks = tasks
        self.workspaces = workspaces
        self.providers = providers
        self.isRefreshing = isRefreshing
    }
}
