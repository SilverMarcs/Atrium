import Foundation

/// The sidebar's grouping: active tasks first, then snoozed, then settled.
/// Settling takes precedence, so a settled task never also counts as snoozed.
struct TaskSections<Task: Identifiable> {
    let active: [Task]
    let snoozed: [Task]
    let settled: [Task]

    init(_ tasks: [Task], isSettled: (Task) -> Bool, isSnoozed: (Task) -> Bool) {
        var active: [Task] = []
        var snoozed: [Task] = []
        var settled: [Task] = []
        for task in tasks {
            if isSettled(task) {
                settled.append(task)
            } else if isSnoozed(task) {
                snoozed.append(task)
            } else {
                active.append(task)
            }
        }
        self.active = active
        self.snoozed = snoozed
        self.settled = settled
    }

    var isEmpty: Bool { active.isEmpty && snoozed.isEmpty && settled.isEmpty }
    var ids: [Task.ID] { (active + snoozed + settled).map(\.id) }
}
