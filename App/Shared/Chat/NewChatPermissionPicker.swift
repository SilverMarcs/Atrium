import AtriumClient
import AtriumProtocol
import SwiftUI

/// The same permission-mode menu as the chat's, presented as a new-chat row.
struct NewChatPermissionPicker: View {
    let host: HostClient
    let draft: TaskDraft

    var body: some View {
        if let task = host.draftTask(draft.id), host.availableProviders.contains(draft.provider),
           let selection = task.permissionSelection(using: host.models(for: draft.provider)) {
            // A chat not yet started takes any mode without a restart.
            TaskPermissionMenu(
                selection: selection, restartMode: .constant(nil),
                perform: { host.send(.task(id: draft.id, action: $0)) },
                isNewChatRow: true
            )
        }
    }
}
