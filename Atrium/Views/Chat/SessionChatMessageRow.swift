import AppKit
import AtriumClient
import AtriumProtocol
import SwiftUI

/// Desktop message geometry from the original chat detail, using normalized transcripts.
struct SessionChatMessageRow: View {
  let message: TranscriptMessage
  let isStreaming: Bool
  var edit: (() -> Void)?
  var editEnabled = true
  var pendingPrompt: PendingPrompt?
  var retry: () -> Void = {}

  var body: some View {
    switch message.role {
    case .user:
      if let pendingPrompt {
        PendingPromptRow(
          prompt: pendingPrompt, retry: retry, sendFlight: { $0.flight(forTimelineID: message.id) })
      } else {
        UserMessageView(
          text: message.blocks.compactMap(\.text).joined(separator: "\n"),
          images: message.images ?? [],
          isFromAgent: message.relay != nil,
          edit: edit, editEnabled: editEnabled,
          sendFlight: { $0.flight(forTimelineID: message.id) })
      }
    case .assistant:
      VStack(alignment: .leading, spacing: 8) {
        AssistantMessageView(blocks: message.blocks, isStreaming: isStreaming)
      }
      .contentShape(.rect)
      .transaction { $0.animation = nil }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.trailing, 30)
    }
  }
}
