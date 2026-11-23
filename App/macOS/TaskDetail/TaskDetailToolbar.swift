import AtriumClient
import AtriumProtocol
import SwiftUI

/// The Mac toolbar of a task's detail view.
struct TaskDetailToolbar: ToolbarContent {
    let item: HostTask
    @Environment(AppModel.self) private var app

    var body: some ToolbarContent {
        if let parent = item.parent {
            ToolbarItem(placement: .navigation) {
                TaskParentButton(parent: parent, hostID: item.host.id) { app.selection = $0 }
            }
        } else if item.task.workspaceID != nil {
            ToolbarItem(placement: .navigation) {
                Button("New Chat", systemImage: "square.and.pencil") { app.hosts.openNewChat() }
                    .help("New Chat")
                    .disabled(!app.hosts.canStartNewChat)
            }
        }
        // Pull requests and subagents share one group; the side chat sits on its own.
        if !item.task.pullRequests.isEmpty {
            ToolbarItem {
                PullRequestMenu(item: item)
            }
        }
        if item.hasSubagents {
            ToolbarItem {
                SubagentMenu(item: item) { app.selection = $0 }
            }
        }
        if hasSideChatButton, !item.task.pullRequests.isEmpty || item.hasSubagents {
            ToolbarSpacer(.fixed)
        }
        if item.task.isSideChat {
            ToolbarItem {
                NewSideChatButton(sideChat: item) { app.selection = $0 }
            }
        } else if hasSideChatButton {
            ToolbarItem {
                SideChatButton(item: item) { app.selection = $0 }
            }
        }
    }

    private var hasSideChatButton: Bool {
        item.task.isSideChat || item.task.actions.contains(.sideChat) || item.sideChat != nil
    }
}
