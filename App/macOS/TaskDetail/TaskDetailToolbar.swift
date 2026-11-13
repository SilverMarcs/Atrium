import AtriumClient
import AtriumProtocol
import SwiftUI

/// The toolbar's permission-mode button, which asks before restarting the chat.
private struct TaskPermissionToolbarMenu: View {
    let item: HostTask
    let selection: TaskPermissionSelection
    @State private var restartMode: PermissionMode?

    var body: some View {
        let perform = { (action: TaskAction) in item.host.send(.task(id: item.task.id, action: action)) }
        TaskPermissionMenu(selection: selection, restartMode: $restartMode, perform: perform, showsToolbarLabel: true)
            .permissionRestartAlert($restartMode, provider: item.task.provider, perform: perform)
    }
}

/// The Mac toolbar of a task's detail view.
struct TaskDetailToolbar: ToolbarContent {
    let item: HostTask
    @Binding var showingScratchPad: Bool
    @Environment(AppModel.self) private var app

    var body: some ToolbarContent {
        if !TaskDraft.isDraftID(item.task.id), !item.task.isSubagent, !item.task.isSideChat {
            ToolbarItem {
                let models = item.host.models(for: item.task.provider)
                TaskModelMenu(
                    provider: item.task.provider, selection: item.task.modelSelection, models: models,
                    perform: { item.host.send(.task(id: item.task.id, action: $0)) }, showsToolbarLabel: true
                )
                .disabled(models.isEmpty)
            }
            if let permissions = item.task.permissionSelection(using: item.host.models(for: item.task.provider)) {
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    TaskPermissionToolbarMenu(item: item, selection: permissions)
                }
                ToolbarSpacer(.fixed)
            }
        }
        // The terminal runs on the task's host, so only this Mac's own tasks open in one.
        if item.host.isLocal, item.task.actions.contains(.openTerminal) {
            ToolbarItem {
                TaskTerminalButton(item: item)
            }
        }
        if let parent = item.parent {
            ToolbarItem(placement: .navigation) {
                TaskParentButton(parent: parent, hostID: item.host.id) { app.selection = $0 }
            }
        } else if item.task.workspaceID != nil {
            ToolbarItem(placement: .navigation) {
                ScratchPadButton(isPresented: $showingScratchPad)
            }
        }
        if item.hasSubagents || item.task.isSideChat || item.task.actions.contains(.sideChat) || item.sideChat != nil {
            ToolbarSpacer(.fixed)
        }
        if item.hasSubagents {
            ToolbarItem {
                SubagentMenu(item: item) { app.selection = $0 }
            }
        }
        if item.task.isSideChat {
            ToolbarItem {
                NewSideChatButton(sideChat: item) { app.selection = $0 }
            }
        } else if item.task.actions.contains(.sideChat) || item.sideChat != nil {
            ToolbarItem {
                SideChatButton(item: item) { app.selection = $0 }
            }
        }
    }
}
