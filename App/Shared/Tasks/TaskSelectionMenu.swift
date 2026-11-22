import AtriumClient
import AtriumProtocol
import SwiftUI

/// The context menu for a list's selected tasks: a single task's own menu, or
/// for several, only the actions that apply to at least one of them, each
/// performed on just those.
struct TaskSelectionMenu: View {
    let items: [HostTask]
    let perform: (TaskMenuAction, [HostTask]) -> Void

    private static let groups: [[TaskMenuAction]] = [
        [.settle, .restore, .snooze(nil), .unsnooze],
        [.markRead, .markUnread],
        [.delete],
    ]

    var body: some View {
        if items.count == 1, let item = items.first {
            TaskContextMenu(state: item.menuState) { perform($0, [item]) }
        } else if items.count > 1 {
            ForEach(Self.groups, id: \.self) { group in
                Section {
                    ForEach(group, id: \.self) { action in
                        let targets = items.filter { $0.task.menuState.offers(action) }
                        if case .snooze = action, !targets.isEmpty {
                            Menu(action.title(count: targets.count), systemImage: action.systemImage) {
                                snoozeButtons(SnoozeDuration.menu, targets)
                                Menu("More") {
                                    snoozeButtons(SnoozeDuration.more, targets)
                                }
                            }
                        } else if !targets.isEmpty {
                            Button(action.title(count: targets.count), systemImage: action.systemImage,
                                   role: action == .delete ? .destructive : nil) {
                                perform(action, targets)
                            }
                        }
                    }
                }
            }
        }
    }

    private func snoozeButtons(_ durations: [SnoozeDuration], _ targets: [HostTask]) -> some View {
        ForEach(durations) { duration in
            Button(duration.title) { perform(.snooze(duration), targets) }
        }
    }
}

extension TaskMenuAction {
    /// The action's title for a number of tasks at once.
    func title(count: Int) -> String {
        guard count > 1 else { return title }
        return switch self {
        case .settle: "Settle \(count) Threads"
        case .restore: "Restore \(count) Threads"
        case .snooze: "Snooze \(count) Threads"
        case .unsnooze: "Unsnooze \(count) Threads"
        case .markRead: "Mark \(count) as Read"
        case .markUnread: "Mark \(count) as Unread"
        case .delete: "Delete \(count) Threads"
        case .fork, .forkInto, .rename: title
        }
    }
}
