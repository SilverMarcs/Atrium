import SwiftUI

/// A task's pull requests, project links, side chat and subagents in one menu.
struct TaskMoreMenu: View {
    let item: HostTask
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
            let workspaceID = item.task.workspaceID
            let hasPreviews = !TaskDraft.isDraftID(item.task.id)
            if workspaceID != nil || hasPreviews {
                Section {
                    if let workspaceID {
                        ProjectLinks(
                            workspace: WorkspaceRef(hostID: item.host.id, workspaceID: workspaceID),
                            hasRunningCommands: runningCommands > 0
                        )
                    }
                    if hasPreviews { LivePreviewLinks(item: item) }
                } header: {
                    if let workspaceID, let title = item.host.scope(for: workspaceID).title {
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

    private func pullRequestSummary(_ pullRequests: [PullRequest]) -> String {
        let open = pullRequests.count(where: \.isOpen)
        return open > 0 ? "\(open) open · \(pullRequests.count) total" : "\(pullRequests.count) total"
    }

    private func subagentSummary(count: Int) -> String {
        let working = item.workingSubagents
        return working > 0 ? "\(working) working · \(count) total" : "\(count) total"
    }
}

/// Each source pushes its own screen alongside the other project destinations.
struct LivePreviewLinks: View {
    let item: HostTask

    var body: some View {
        let ref = TaskRef(hostID: item.host.id, taskID: item.task.id)
        ForEach(LivePreviewSource.allCases) { source in
            NavigationLink(value: Route.livePreview(ref, source: source)) {
                Label(source.title, systemImage: source.symbol)
            }
            .disabled(!item.host.isConnected)
        }
    }
}
