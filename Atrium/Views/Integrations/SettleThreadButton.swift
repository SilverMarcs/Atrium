import SwiftUI

struct SettleThreadButton: View {
    @Environment(AgentIntegrationStore.self) private var integrations
    @Environment(TaskSessionController.self) private var sessions
    @Environment(\.undoManager) private var undoManager
    let thread: AgentThread

    var body: some View {
        if integrations.settledThreadIDs.contains(thread.id) {
            Button("Restore Thread", systemImage: "arrow.uturn.backward") {
                sessions.restore(thread, undoManager: undoManager)
            }
            .disabled(sessions.isOpening || integrations.deletingThreadIDs.contains(thread.id) || integrations.stoppingThreadIDs.contains(thread.id) || integrations.renamingThreadIDs.contains(thread.id))
        } else {
            Button("Settle Thread", systemImage: "checkmark") {
                sessions.settle(thread, undoManager: undoManager)
            }
            .tint(.green)
            .disabled(sessions.isOpening || integrations.deletingThreadIDs.contains(thread.id) || integrations.stoppingThreadIDs.contains(thread.id) || integrations.renamingThreadIDs.contains(thread.id))
        }
    }
}
