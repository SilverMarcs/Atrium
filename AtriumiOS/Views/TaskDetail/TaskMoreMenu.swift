import AtriumClient
import AtriumProtocol
import SwiftUI

/// A task's model, project links and scratch pad in one menu, and its delegated sessions when it includes them.
struct TaskMoreMenu: View {
    let item: HostTask
    let models: [AgentModel]
    let includesDelegatedTasks: Bool
    @Binding var showingScratchPad: Bool
    @Environment(\.openDelegatedTask) private var openDelegatedTask

    var body: some View {
        Menu {
            if !models.isEmpty {
                Section {
                    TaskModelMenu(
                        provider: item.task.provider, selection: item.task.modelSelection, models: models
                    ) { action in
                        item.host.send(.task(id: item.task.id, action: action))
                    }
                }
            }
            if let workspaceID = item.task.workspaceID {
                Section {
                    ProjectLinks(
                        workspace: WorkspaceRef(hostID: item.host.id, workspaceID: workspaceID),
                        root: item.host.workspace(workspaceID)?.path ?? ""
                    )
                    ScratchPadButton(isPresented: $showingScratchPad)
                }
            }
            if includesDelegatedTasks, item.hasDelegatedTasks {
                Section("Subagents") {
                    DelegatedTaskButtons(item: item, open: openDelegatedTask)
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        // Only the menu containing subagents counts their ongoing work.
        .badge(includesDelegatedTasks ? item.workingDelegatedTasks : 0)
    }
}
