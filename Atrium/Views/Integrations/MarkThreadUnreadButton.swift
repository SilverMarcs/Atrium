import SwiftUI

struct MarkThreadUnreadButton: View {
    @Environment(AgentIntegrationStore.self) private var integrations
    let thread: AgentThread

    var body: some View {
        Button("Mark as Unread", systemImage: "envelope.badge") {
            Task { await integrations.markUnread(thread) }
        }
        .tint(.blue)
    }
}
