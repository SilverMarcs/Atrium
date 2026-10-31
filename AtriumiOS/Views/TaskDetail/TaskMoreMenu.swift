import AtriumClient
import AtriumProtocol
import SwiftUI

/// A task's model, project links and scratch pad in one menu, its side chat,
/// and its subagents when it includes them.
struct TaskMoreMenu: View {
    let item: HostTask
    let models: [AgentModel]
    let includesSubagents: Bool
    @Binding var showingScratchPad: Bool
    @Environment(\.openSubagent) private var openSubagent
    @Environment(\.openSideChat) private var openSideChat

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
                    ProjectLinks(workspace: WorkspaceRef(hostID: item.host.id, workspaceID: workspaceID))
                } header: {
                    // The branch or worktree the project's pages show.
                    if let title = item.host.scope(for: workspaceID).title {
                        Text(title)
                    }
                }
                Section {
                    ScratchPadButton(isPresented: $showingScratchPad)
                }
            }
            if item.sideChat != nil || item.task.actions.contains(.sideChat) {
                Section {
                    SideChatButton(item: item, open: openSideChat)
                }
            }
            if includesSubagents, item.hasSubagents {
                Section("Subagents") {
                    SubagentButtons(item: item, open: openSubagent)
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        // Only the menu containing subagents counts their ongoing work.
        .badge(includesSubagents ? item.workingSubagents : 0)
    }
}
