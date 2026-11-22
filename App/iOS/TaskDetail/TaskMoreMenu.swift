import AtriumClient
import AtriumProtocol
import SwiftUI

/// A task's project links, side chat and subagents in one menu.
struct TaskMoreMenu: View {
    let item: HostTask
    @Environment(\.openSubagent) private var openSubagent
    @Environment(\.openSideChat) private var openSideChat

    var body: some View {
        Menu {
            if !item.task.pullRequests.isEmpty {
                Section("Pull Requests") {
                    PullRequestButtons(item: item)
                }
            }
            if let workspaceID = item.task.workspaceID {
                Section {
                    ProjectLinks(
                        workspace: WorkspaceRef(hostID: item.host.id, workspaceID: workspaceID),
                        hasRunningCommands: runningCommands > 0
                    )
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
            // A lone subagent shows inline; several get their own menu.
            let subagentCount = item.subagents.count
            if subagentCount == 1 {
                Section("Subagents") {
                    SubagentButtons(item: item, open: openSubagent)
                }
            } else if subagentCount > 1 {
                Section {
                    Menu {
                        SubagentButtons(item: item, open: openSubagent)
                    } label: {
                        Label("Subagents", systemImage: "rectangle.stack")
                        Text(subagentSummary(count: subagentCount))
                    }
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .badge(item.workingSubagents + runningCommands)
    }

    private var runningCommands: Int {
        item.task.workspaceID.flatMap { item.host.workspace($0)?.runningCount } ?? 0
    }

    private func subagentSummary(count: Int) -> String {
        let working = item.workingSubagents
        return working > 0 ? "\(working) working · \(count) total" : "\(count) total"
    }
}
