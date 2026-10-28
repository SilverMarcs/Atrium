import Foundation

/// Changes since the last tasks snapshot or delta sent to this client.
nonisolated struct WireTasksDelta: Codable, Sendable {
    var upsertedTasks: [WireTask] = []
    var removedTaskIDs: [String] = []
    var upsertedWorkspaces: [WireWorkspace] = []
    var removedWorkspaceIDs: [UUID] = []
    /// The full project order, present only when it changed: projects can be
    /// reordered on the host, and new ones are added at the top.
    var workspaceOrder: [UUID]?
    /// The full provider list, present only when it changed.
    var providers: [WireProvider]?
    /// Present only when it changed.
    var isRefreshing: Bool?

    var isEmpty: Bool {
        upsertedTasks.isEmpty && removedTaskIDs.isEmpty && upsertedWorkspaces.isEmpty
            && removedWorkspaceIDs.isEmpty && workspaceOrder == nil && providers == nil && isRefreshing == nil
    }

    init(from old: WireTasksSnapshot, to new: WireTasksSnapshot) {
        (upsertedTasks, removedTaskIDs) = Self.changes(from: old.tasks, to: new.tasks)
        (upsertedWorkspaces, removedWorkspaceIDs) = Self.changes(from: old.workspaces, to: new.workspaces)
        let order = new.workspaces.map(\.id)
        if old.workspaces.map(\.id) != order { workspaceOrder = order }
        if old.providers != new.providers { providers = new.providers }
        if old.isRefreshing != new.isRefreshing { isRefreshing = new.isRefreshing }
    }

    private enum CodingKeys: String, CodingKey {
        case upsertedTasks, removedTaskIDs, upsertedWorkspaces, removedWorkspaceIDs, workspaceOrder, providers, isRefreshing
    }

    // Empty lists are left out: most deltas touch a single task.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        upsertedTasks = try container.decodeIfPresent([WireTask].self, forKey: .upsertedTasks) ?? []
        removedTaskIDs = try container.decodeIfPresent([String].self, forKey: .removedTaskIDs) ?? []
        upsertedWorkspaces = try container.decodeIfPresent([WireWorkspace].self, forKey: .upsertedWorkspaces) ?? []
        removedWorkspaceIDs = try container.decodeIfPresent([UUID].self, forKey: .removedWorkspaceIDs) ?? []
        workspaceOrder = try container.decodeIfPresent([UUID].self, forKey: .workspaceOrder)
        providers = try container.decodeIfPresent([WireProvider].self, forKey: .providers)
        isRefreshing = try container.decodeIfPresent(Bool.self, forKey: .isRefreshing)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !upsertedTasks.isEmpty { try container.encode(upsertedTasks, forKey: .upsertedTasks) }
        if !removedTaskIDs.isEmpty { try container.encode(removedTaskIDs, forKey: .removedTaskIDs) }
        if !upsertedWorkspaces.isEmpty { try container.encode(upsertedWorkspaces, forKey: .upsertedWorkspaces) }
        if !removedWorkspaceIDs.isEmpty { try container.encode(removedWorkspaceIDs, forKey: .removedWorkspaceIDs) }
        try container.encodeIfPresent(workspaceOrder, forKey: .workspaceOrder)
        try container.encodeIfPresent(providers, forKey: .providers)
        try container.encodeIfPresent(isRefreshing, forKey: .isRefreshing)
    }

    private static func changes<Element: Identifiable & Equatable>(
        from old: [Element], to new: [Element]
    ) -> ([Element], [Element.ID]) {
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let upserted = new.filter { previous[$0.id] != $0 }
        let remaining = Set(new.map(\.id))
        return (upserted, old.map(\.id).filter { !remaining.contains($0) })
    }
}
