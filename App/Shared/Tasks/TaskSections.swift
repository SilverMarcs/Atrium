import Foundation

/// A sidebar section, which tasks move between from their menus.
nonisolated enum TaskSection: Hashable, CaseIterable, Sendable {
    case active
    case snoozed
    case settled
}

/// The sidebar's grouping: active tasks first, then snoozed, then settled.
struct TaskSections<Task: Identifiable> {
    let active: [Task]
    let snoozed: [Task]
    let settled: [Task]

    init(_ tasks: [Task], section: (Task) -> TaskSection) {
        var grouped: [TaskSection: [Task]] = [:]
        for task in tasks { grouped[section(task), default: []].append(task) }
        active = grouped[.active] ?? []
        snoozed = grouped[.snoozed] ?? []
        settled = grouped[.settled] ?? []
    }

    subscript(section: TaskSection) -> [Task] {
        switch section {
        case .active: active
        case .snoozed: snoozed
        case .settled: settled
        }
    }

    var isEmpty: Bool { active.isEmpty && snoozed.isEmpty && settled.isEmpty }
    var ids: [Task.ID] { (active + snoozed + settled).map(\.id) }

    /// The tasks of the sections on screen, leaving out collapsed ones.
    func ids(shown isShown: (TaskSection) -> Bool) -> [Task.ID] {
        TaskSection.allCases.filter(isShown).flatMap { self[$0] }.map(\.id)
    }
}
