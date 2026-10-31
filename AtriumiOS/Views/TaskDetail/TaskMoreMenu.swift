import AtriumClient
import AtriumProtocol
import SwiftUI

/// A task's scratch pad, project links and model in one menu, and its delegated sessions when it includes them.
struct TaskMoreMenu: View {
    let item: HostTask
    let models: [AgentModel]
    let includesDelegatedTasks: Bool
    @Binding var showingScratchPad: Bool
    @Environment(\.openDelegatedTask) private var openDelegatedTask

    var body: some View {
        Menu {
            if let workspaceID = item.task.workspaceID {
                Section {
                    ScratchPadButton(isPresented: $showingScratchPad)
                }
                Section {
                    ProjectLinks(workspace: WorkspaceRef(hostID: item.host.id, workspaceID: workspaceID))
                } header: {
                    // The branch or worktree the project's pages show.
                    if let title = item.host.scope(for: workspaceID).title {
                        Text(title)
                    }
                }
            }
            if !models.isEmpty {
                Section {
                    TaskModelMenu(
                        provider: item.task.provider, selection: item.task.modelSelection, models: models
                    ) { action in
                        item.host.send(.task(id: item.task.id, action: action))
                    }
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
