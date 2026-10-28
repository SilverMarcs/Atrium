import Foundation

nonisolated extension WireTasksSnapshot {
    /// Tasks that have just finished or started waiting for input since
    /// `previous`, which is what the phone is alerted about. A task that's
    /// new, settled or snoozed doesn't count.
    func tasksNeedingAttention(since previous: WireTasksSnapshot) -> [WireTask] {
        let before = Dictionary(previous.tasks.map { ($0.id, $0.status) }, uniquingKeysWith: { $1 })
        return tasks.filter { task in
            guard !task.isSettled, !task.isSnoozed,
                  let status = before[task.id], status != task.status, status != .unknown else { return false }
            return task.status == .done || task.status == .waiting
        }
    }
}
