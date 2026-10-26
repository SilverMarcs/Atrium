import Foundation

nonisolated extension WireTasksSnapshot {
    mutating func apply(_ delta: WireTasksDelta) {
        tasks = Self.merging(tasks, upserted: delta.upsertedTasks, removed: delta.removedTaskIDs)
        workspaces = Self.merging(workspaces, upserted: delta.upsertedWorkspaces, removed: delta.removedWorkspaceIDs)
        if let order = delta.workspaceOrder {
            let positions = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            workspaces.sort { positions[$0.id, default: .max] < positions[$1.id, default: .max] }
        }
        if let providers = delta.providers { self.providers = providers }
    }

    private static func merging<Element: Identifiable>(
        _ elements: [Element], upserted: [Element], removed: [Element.ID]
    ) -> [Element] {
        let removed = Set(removed)
        var result = elements.filter { !removed.contains($0.id) }
        for element in upserted {
            if let index = result.firstIndex(where: { $0.id == element.id }) {
                result[index] = element
            } else {
                result.append(element)
            }
        }
        return result
    }
}
