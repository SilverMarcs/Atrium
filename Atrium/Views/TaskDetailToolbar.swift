import AtriumClient
import AtriumProtocol
import SwiftUI

/// The Mac toolbar of a task's detail view.
struct TaskDetailToolbar: ToolbarContent {
    let item: HostTask
    let hasTerminal: Bool
    let showsTerminal: Bool
    @Binding var presentation: String
    @Binding var showingScratchPad: Bool
    @Environment(AppModel.self) private var app

    var body: some ToolbarContent {
        if !showsTerminal, !TaskDraft.isDraftID(item.task.id), !item.task.isSubagent, !item.task.isSideChat {
            ToolbarItem {
                let models = item.host.models(for: item.task.provider)
                TaskModelMenu(
                    provider: item.task.provider, selection: item.task.modelSelection, models: models,
                    perform: { item.host.send(.task(id: item.task.id, action: $0)) }, showsToolbarLabel: true
                )
                .disabled(models.isEmpty)
            }
        }
        if hasTerminal {
            ToolbarItem {
                TaskSessionViewPicker(selection: $presentation)
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
