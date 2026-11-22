import Foundation

public nonisolated struct WireTasksSnapshot: Codable, Sendable, Equatable {
    public var tasks: [WireTask]
    public var workspaces: [WireWorkspace]
    public var providers: [WireProvider]
    /// Whether the host is reloading its tasks from their providers.
    public var isRefreshing: Bool = false
    /// How long swiping a task snoozes it, as set on the host.
    public var snoozeDuration: SnoozeDuration = .default

    private enum CodingKeys: String, CodingKey {
        case tasks, workspaces, providers, isRefreshing, snoozeDuration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decode(ProviderRows<WireTask>.self, forKey: .tasks).values
        workspaces = try container.decode([WireWorkspace].self, forKey: .workspaces)
        providers = try container.decode(ProviderRows<WireProvider>.self, forKey: .providers).values
        isRefreshing = try container.decodeIfPresent(Bool.self, forKey: .isRefreshing) ?? false
        snoozeDuration = try container.decodeIfPresent(SnoozeDuration.self, forKey: .snoozeDuration) ?? .default
    }

    public init(
        tasks: [WireTask], workspaces: [WireWorkspace], providers: [WireProvider], isRefreshing: Bool = false,
        snoozeDuration: SnoozeDuration = .default
    ) {
        self.tasks = tasks
        self.workspaces = workspaces
        self.providers = providers
        self.isRefreshing = isRefreshing
        self.snoozeDuration = snoozeDuration
    }
}
