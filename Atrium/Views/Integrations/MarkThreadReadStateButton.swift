import SwiftUI

struct MarkThreadReadStateButton: View {
    @Environment(AgentIntegrationStore.self) private var integrations
    @Environment(TaskSessionController.self) private var sessions
    let thread: AgentThread

    var body: some View {
        Button(
            thread.hasUnreadResult ? "Mark as Read" : "Mark as Unread",
            systemImage: thread.hasUnreadResult ? "envelope.open" : "envelope.badge"
        ) {
            Task {
                if thread.hasUnreadResult {
                    await integrations.markRead(thread)
                } else {
                    await integrations.markUnread(thread)
                }
            }
        }
        .tint(.blue)
        .disabled(sessions.isOpening || !(thread.hasUnreadResult
            ? integrations.canMarkRead(thread)
            : integrations.canMarkUnread(thread)))
    }
}
