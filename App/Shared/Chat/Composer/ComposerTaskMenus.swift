import AtriumClient
import AtriumProtocol
import SwiftUI

/// The task's model menu in the composer's row, before dictation.
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

/// The task's permission-mode menu in the composer's row, after the
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
    /// Side chats run with their parent's settings; ordinary chats and drafts
    /// offer their model and permission menus in the composer.
    var offersComposerMenus: Bool {
        !task.isSubagent && !task.isSideChat
    }
}

private extension View {
    func composerRowMenuStyle() -> some View {
        self
            #if os(macOS)
            .menuStyle(.button)
            #endif
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
    }
}
