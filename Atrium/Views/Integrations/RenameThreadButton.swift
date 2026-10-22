import SwiftUI

struct RenameThreadButton: View {
    @Environment(AgentIntegrationStore.self) private var integrations
    @Environment(TaskSessionController.self) private var sessions
    let thread: AgentThread
    let action: () -> Void

    var body: some View {
        Button("Rename Chat", systemImage: "pencil", action: action)
            .disabled(sessions.isOpening || !integrations.canRename(thread))
    }
}
