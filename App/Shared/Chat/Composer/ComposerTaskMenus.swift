import AtriumClient
import AtriumProtocol
import SwiftUI

/// The task's model menu in the composer's row, before dictation, after a
/// ring showing context usage once its provider has said.
struct ComposerModelMenu: View {
    let item: HostTask

    /// The row's width for the menu and its ring, which the iPhone and iPad
    /// glass layer reserves too.
    static func width(for item: HostTask) -> CGFloat {
        ComposerBarLayout.menuControlSize + (item.task.contextUsage == nil ? 0 : ComposerContextRing.addedWidth)
    }

    var body: some View {
        let models = item.host.models(for: item.task.provider)
        HStack(spacing: ComposerContextRing.spacing) {
            if let usage = item.task.contextUsage {
                ComposerContextRing(usage: usage)
            }
            TaskModelMenu(
                provider: item.task.provider, selection: item.task.modelSelection, models: models,
                perform: { item.host.send(.task(id: item.task.id, action: $0)) }, isComposerRow: true
            )
            .disabled(models.isEmpty)
            .composerRowMenuStyle()
        }
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
