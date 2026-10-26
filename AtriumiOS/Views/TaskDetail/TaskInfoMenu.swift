import SwiftUI

/// The task's actions under the model and effort it last ran with, with its
/// details.
struct TaskInfoMenu: View {
    @Environment(CompanionClient.self) private var client
    let task: WireTask
    @Binding var taskToRename: WireTask?
    @Binding var taskToDelete: WireTask?
    @Binding var showingDetails: Bool

    var body: some View {
        Menu {
            Section(task.modelSummary ?? task.provider.name) {
                TaskContextMenu(state: task.menuState) { action in
                    switch action {
                    case .rename: taskToRename = task
                    case .delete: taskToDelete = task
                    default: client.perform(action, on: task)
                    }
                }
                Divider()
                Button("Details", systemImage: "info.circle") { showingDetails = true }
            }
        } label: {
            Label("Info", systemImage: "info")
        }
    }
}
