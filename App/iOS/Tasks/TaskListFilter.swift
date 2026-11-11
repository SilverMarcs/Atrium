import Foundation

/// Which of the sidebar's sections the task list shows.
enum TaskListFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case snoozed
    case settled

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All Tasks"
        case .active: "Active"
        case .snoozed: "Snoozed"
        case .settled: "Settled"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .active: "bubble.left.and.bubble.right"
        case .snoozed: "moon.zzz"
        case .settled: "checkmark"
        }
    }
}
