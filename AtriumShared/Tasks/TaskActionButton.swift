import SwiftUI

/// One task action as a button, worded and tinted the same in both apps.
struct TaskActionButton: View {
    let action: TaskMenuAction
    let state: TaskMenuState
    /// Swipe actions drop the destructive role so a row stays until a delete is confirmed.
    var role: ButtonRole?
    let perform: (TaskMenuAction) -> Void

    var body: some View {
        Button(action.title, systemImage: action.systemImage, role: role) { perform(action) }
            .tint(tint)
            .disabled(!state.allowed.allows(action))
    }

    private var tint: Color? {
        switch action {
        case .settle: .green
        case .snooze: .indigo
        case .markRead, .markUnread: .blue
        case .delete: .red
        case .restore, .unsnooze, .fork, .rename: nil
        }
    }
}

extension TaskMenuAction {
    var title: String {
        switch self {
        case .settle: "Settle Thread"
        case .restore: "Restore Thread"
        case .snooze: "Snooze for a Day"
        case .unsnooze: "Unsnooze Thread"
        case .fork: "Fork Chat"
        case .rename: "Rename Chat"
        case .markRead: "Mark as Read"
        case .markUnread: "Mark as Unread"
        case .delete: "Delete Thread"
        }
    }

    var systemImage: String {
        switch self {
        case .settle: "checkmark"
        case .restore: "arrow.uturn.backward"
        case .snooze: "moon.zzz"
        case .unsnooze: "bell"
        case .fork: "arrow.triangle.branch"
        case .rename: "pencil"
        case .markRead: "envelope.open"
        case .markUnread: "envelope.badge"
        case .delete: "trash"
        }
    }
}
