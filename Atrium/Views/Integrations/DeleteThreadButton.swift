import SwiftUI

struct DeleteThreadButton: View {
    @Environment(AgentIntegrationStore.self) private var integrations
    @Environment(TaskSessionController.self) private var sessions
    let thread: AgentThread
    var role: ButtonRole? = .destructive
    let action: () -> Void

    var body: some View {
        if integrations.supportsDeletion(thread) {
            Button("Delete Thread", systemImage: "trash", role: role, action: action)
                .tint(.red)
                .disabled(sessions.isOpening || !integrations.canDelete(thread))
        }
    }
}
