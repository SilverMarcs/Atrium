import AtriumProtocol
import SwiftUI

/// One message of a task's transcript: the user's prompt, or the agent's reply.
struct TranscriptMessageRow: View {
    let message: TranscriptMessage
    let isStreaming: Bool
    var edit: (() -> Void)?
    var editEnabled = true

    var body: some View {
        switch message.role {
        case .user:
            UserMessageView(
                text: message.blocks.compactMap(\.text).joined(separator: "\n"),
                images: message.images ?? [],
                edit: edit, editEnabled: editEnabled,
                sendFlight: { [id = message.id] in $0.flight(forConfirmed: id) }
            )
        case .assistant:
            AssistantMessageView(blocks: message.blocks, isStreaming: isStreaming)
        }
    }
}
