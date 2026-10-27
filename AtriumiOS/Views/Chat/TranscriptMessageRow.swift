import SwiftUI

/// One message of a task's transcript: the user's prompt, or the agent's reply.
struct TranscriptMessageRow: View {
    let message: TranscriptMessage
    let isStreaming: Bool

    var body: some View {
        switch message.role {
        case .user:
            UserMessageView(
                text: message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n"),
                sendFlight: { [id = message.id] in $0.flight(forConfirmed: id) }
            )
        case .assistant:
            AssistantMessageView(blocks: message.blocks, isStreaming: isStreaming)
        }
    }
}
