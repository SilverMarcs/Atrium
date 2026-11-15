import AtriumClient
import AtriumProtocol
import SwiftUI

/// A task's project links, scratch pad, side chat and subagents in one menu.
struct TaskMoreMenu: View {
    let item: HostTask
    @Binding var showingScratchPad: Bool
    @Environment(\.openSubagent) private var openSubagent
    @Environment(\.openSideChat) private var openSideChat

    var body: some View {
        Menu {
            if !item.task.pullRequests.isEmpty {
                Section("Pull Requests") {
                    PullRequestButtons(pullRequests: item.task.pullRequests)
                }
            }
            if let workspaceID = item.task.workspaceID {
                Section {
                    ProjectLinks(workspace: WorkspaceRef(hostID: item.host.id, workspaceID: workspaceID))
                    ScratchPadButton(isPresented: $showingScratchPad)
                } header: {
                    // The branch or worktree the project's pages show.
                    if let title = item.host.scope(for: workspaceID).title {
                        Text(title)
                    }
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
    }
}
