import SwiftUI

/// The task context menu shared by the Mac sidebar and the companion. Rename
/// and delete are passed to `perform` like any action; callers confirm them.
struct TaskContextMenu: View {
    let state: TaskMenuState
    let perform: (TaskMenuAction) -> Void

    var body: some View {
        TaskActionButton(action: state.settleAction, state: state, perform: perform)
        if let snoozeAction = state.snoozeAction {
            if case .snooze = snoozeAction {
                Menu(snoozeAction.title, systemImage: snoozeAction.systemImage) {
                    snoozeButtons(SnoozeDuration.menu)
                    Menu("More") {
                        snoozeButtons(SnoozeDuration.more)
                    }
                }
                .disabled(!state.allowed.allows(snoozeAction))
            } else {
                TaskActionButton(action: snoozeAction, state: state, perform: perform)
            }
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

    private func snoozeButtons(_ durations: [SnoozeDuration]) -> some View {
        ForEach(durations) { duration in
            Button(duration.title) { perform(.snooze(duration)) }
        }
    }
}
