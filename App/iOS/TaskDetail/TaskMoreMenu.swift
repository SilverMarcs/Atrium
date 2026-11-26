import SwiftUI

/// A task's pull requests, project links, side chat and subagents in one menu.
struct TaskMoreMenu: View {
    let item: HostTask
    let openPreview: () -> Void
    @Environment(\.openSubagent) private var openSubagent
    @Environment(\.openSideChat) private var openSideChat

    var body: some View {
        Menu {
            // Like subagents: a lone pull request shows inline; several get their own menu.
            let pullRequests = item.task.pullRequests
            if pullRequests.count == 1 {
                Section("Pull Requests") {
                    PullRequestButtons(item: item)
                }
            } else if let lead = pullRequests.mostPressing {
                Section {
                    Menu {
                        PullRequestButtons(item: item)
                    } label: {
                        Label("Pull Requests", image: lead.icon)
                        Text(pullRequestSummary(pullRequests))
                    }
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
            if !TaskDraft.isDraftID(item.task.id) {
                Section {
                    Button("Live Preview", systemImage: "rectangle.on.rectangle", action: openPreview)
                        .disabled(!item.host.isConnected)
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

    private func pullRequestSummary(_ pullRequests: [PullRequest]) -> String {
        let open = pullRequests.count(where: \.isOpen)
        return open > 0 ? "\(open) open · \(pullRequests.count) total" : "\(pullRequests.count) total"
    }

    private func subagentSummary(count: Int) -> String {
        let working = item.workingSubagents
        return working > 0 ? "\(working) working · \(count) total" : "\(count) total"
    }
}
