import SwiftUI

struct ForkThreadButton: View {
    @Environment(AgentIntegrationStore.self) private var integrations
    @Environment(TaskSessionController.self) private var sessions
    let thread: AgentThread

    var body: some View {
        Button("Fork Chat", systemImage: "arrow.triangle.branch") {
            Task { await sessions.fork(thread) }
        }
        .disabled(sessions.isOpening || !integrations.canFork(thread))
    }
}
