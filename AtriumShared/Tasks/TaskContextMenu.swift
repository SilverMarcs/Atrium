import SwiftUI

/// The task context menu shared by the Mac sidebar and the companion. Rename
/// and delete are passed to `perform` like any action; callers confirm them.
struct TaskContextMenu: View {
    let state: TaskMenuState
    let perform: (TaskMenuAction) -> Void

    var body: some View {
        TaskActionButton(action: state.settleAction, state: state, perform: perform)
        if let snoozeAction = state.snoozeAction {
            TaskActionButton(action: snoozeAction, state: state, perform: perform)
        }

        Divider()

        TaskActionButton(action: .fork, state: state, perform: perform)
        TaskActionButton(action: .rename, state: state, perform: perform)
        TaskActionButton(action: state.readAction, state: state, perform: perform)

        if state.supportsDeletion {
            Divider()
            TaskActionButton(action: .delete, state: state, role: .destructive, perform: perform)
        }
    }
}
