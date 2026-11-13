import AtriumProtocol
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
        if !state.forkProviders.isEmpty {
            Menu("Fork in", systemImage: "arrow.triangle.branch") {
                ForEach(state.forkProviders) { provider in
                    Button {
                        perform(.forkInto(provider))
                    } label: {
                        Label(provider.name, image: provider.symbolName)
                    }
                }
            }
            .disabled(!state.allowed.allows(.fork))
        }

        Divider()

        TaskActionButton(action: .rename, state: state, perform: perform)
        TaskActionButton(action: state.readAction, state: state, perform: perform)

        if state.supportsDeletion {
            Divider()
            TaskActionButton(action: .delete, state: state, role: .destructive, perform: perform)
        }
    }
}
