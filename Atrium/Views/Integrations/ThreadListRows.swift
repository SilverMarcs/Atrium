import SwiftUI

struct ThreadListRows: View {
    @Environment(AgentIntegrationStore.self) private var integrations
    let threads: [AgentThread]
    let requestDeletion: (AgentThread) -> Void
    let requestRename: (AgentThread) -> Void

    var body: some View {
        ForEach(threads) { thread in
            ThreadRowView(thread: thread)
                .tag(thread.id)
                .contextMenu {
                    SettleThreadButton(thread: thread)
                    SnoozeThreadButton(thread: thread)

                    Divider()

                    ForkThreadButton(thread: thread)
                    RenameThreadButton(thread: thread) { requestRename(thread) }

                    MarkThreadReadStateButton(thread: thread)
                    if integrations.supportsDeletion(thread) {
                        Divider()
                        DeleteThreadButton(thread: thread) { requestDeletion(thread) }
                    }
                }
                .swipeActions(edge: .leading) {
                    SettleThreadButton(thread: thread)
                        .labelStyle(.iconOnly)
                    SnoozeThreadButton(thread: thread)
                        .labelStyle(.iconOnly)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    // Keep the row visible until confirmation; a destructive swipe role
                    // would optimistically animate it away before the alert is answered.
                    DeleteThreadButton(thread: thread, role: nil) { requestDeletion(thread) }
                        .labelStyle(.iconOnly)
                    MarkThreadReadStateButton(thread: thread)
                        .labelStyle(.iconOnly)
                }
        }
    }
}
