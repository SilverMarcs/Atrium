import Foundation

nonisolated struct WireTasksSnapshot: Codable, Sendable, Equatable {
    var tasks: [WireTask]
    var workspaces: [WireWorkspace]
    var providers: [WireProvider]
    /// Whether the host is reloading its tasks from their providers.
    var isRefreshing: Bool = false
    /// How long swiping a task snoozes it, as set on the host.
    var snoozeDuration: SnoozeDuration = .default

    private enum CodingKeys: String, CodingKey {
        case tasks, workspaces, providers, isRefreshing, snoozeDuration
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decode(LossyRows<WireTask>.self, forKey: .tasks).values
        workspaces = try container.decode(LossyRows<WireWorkspace>.self, forKey: .workspaces).values
        providers = try container.decode(LossyRows<WireProvider>.self, forKey: .providers).values
        isRefreshing = try container.decodeIfPresent(Bool.self, forKey: .isRefreshing) ?? false
        snoozeDuration = try container.decodeIfPresent(SnoozeDuration.self, forKey: .snoozeDuration) ?? .default
    }

    init(
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
