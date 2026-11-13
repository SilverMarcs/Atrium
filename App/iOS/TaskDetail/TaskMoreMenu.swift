import AtriumClient
import AtriumProtocol
import SwiftUI

/// A task's model, project links, scratch pad, side chat and subagents in one menu.
struct TaskMoreMenu: View {
    let item: HostTask
    let models: [AgentModel]
    @Binding var showingScratchPad: Bool
    @State private var restartMode: PermissionMode?
    @Environment(\.openSubagent) private var openSubagent
    @Environment(\.openSideChat) private var openSideChat

    var body: some View {
        Menu {
            if !item.task.pullRequests.isEmpty {
                Section("Pull Requests") {
                    PullRequestButtons(pullRequests: item.task.pullRequests)
                }
            }
            if !models.isEmpty {
                Section {
                    TaskModelMenu(
                        provider: item.task.provider, selection: item.task.modelSelection, models: models,
                        perform: perform
                    )
                    if let permissions = item.task.permissionSelection(using: models) {
                        TaskPermissionMenu(selection: permissions, restartMode: $restartMode, perform: perform)
                    }
                } header: {
                    if let percent = item.task.contextUsedPercent {
                        Text("\(percent)% context used")
                    } else {
                        Text("Model")
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
            if item.hasSubagents {
                Section("Subagents") {
                    SubagentButtons(item: item, open: openSubagent)
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .badge(item.workingSubagents)
        .permissionRestartAlert($restartMode, provider: item.task.provider, perform: perform)
    }

    private func perform(_ action: TaskAction) {
        item.host.send(.task(id: item.task.id, action: action))
    }
}
