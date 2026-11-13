import AtriumClient
import AtriumProtocol
import SwiftUI

/// The task's model menu in the Mac composer's row, before dictation.
struct ComposerModelMenu: View {
    let item: HostTask

    var body: some View {
        let models = item.host.models(for: item.task.provider)
        TaskModelMenu(
            provider: item.task.provider, selection: item.task.modelSelection, models: models,
            perform: { item.host.send(.task(id: item.task.id, action: $0)) }, isComposerRow: true
        )
        .disabled(models.isEmpty)
        .composerRowMenuStyle()
    }
}

/// The task's permission-mode menu in the Mac composer's row, after the
/// attachment button. It asks before restarting the chat.
struct ComposerPermissionMenu: View {
    let item: HostTask
    let selection: TaskPermissionSelection
    @State private var restartMode: PermissionMode?

    var body: some View {
        let perform = { (action: TaskAction) in item.host.send(.task(id: item.task.id, action: action)) }
        TaskPermissionMenu(selection: selection, restartMode: $restartMode, perform: perform, isComposerRow: true)
            .composerRowMenuStyle()
            .permissionRestartAlert($restartMode, provider: item.task.provider, perform: perform)
    }
}

extension HostTask {
    /// Whether the composer offers the chat's model and permission menus:
    /// not for a new chat, whose pickers sit above it, nor for a side chat,
    /// which runs with its parent's.
    var offersComposerMenus: Bool {
        !TaskDraft.isDraftID(task.id) && !task.isSubagent && !task.isSideChat
    }
}

private extension View {
    func composerRowMenuStyle() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
    }
}
