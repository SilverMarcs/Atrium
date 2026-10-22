import SwiftUI

struct SnoozeThreadButton: View {
    @Environment(AgentIntegrationStore.self) private var integrations
    @Environment(TaskSessionController.self) private var sessions
    @Environment(\.undoManager) private var undoManager
    let thread: AgentThread

    var body: some View {
        if integrations.snoozedUntil[thread.id] != nil {
            Button("Unsnooze Thread", systemImage: "bell") {
                sessions.unsnooze(thread, undoManager: undoManager)
            }
            .disabled(integrations.deletingThreadIDs.contains(thread.id))
        } else if !integrations.settledThreadIDs.contains(thread.id) {
            Button("Snooze for a Day", systemImage: "moon.zzz") {
                sessions.snooze(thread, undoManager: undoManager)
            }
            .tint(.indigo)
            .disabled(!integrations.canSnooze(thread))
        }
    }
}
