import AtriumClient
import AtriumProtocol
import SwiftUI

/// The same model menu used by the chat toolbar, presented as a new-chat row.
struct NewChatModelPicker: View {
    let host: HostClient
    let draft: TaskDraft

    var body: some View {
        if let task = host.draftTask(draft.id), host.enabledProviders.contains(draft.provider) {
            let models = host.models(for: draft.provider)
            TaskModelMenu(
                provider: draft.provider,
                selection: task.modelSelection,
                models: models,
                perform: { host.send(.task(id: draft.id, action: $0)) },
                isNewChatRow: true
            )
            .disabled(models.isEmpty)
        }
    }
}
