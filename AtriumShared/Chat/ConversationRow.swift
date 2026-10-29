import AtriumClient
import AtriumProtocol

/// A stable timeline row before and after a locally sent prompt is confirmed.
struct ConversationRow: Identifiable {
  let message: TranscriptMessage
  var pendingPrompt: PendingPrompt?

  var id: String { message.id }
}

extension ConversationStore {
  /// The task's messages as laid out by `turns`, then its prompts still on their way.
  func rows(for taskID: String, turns: ConversationTurns) -> [ConversationRow] {
    turns.messages.map { ConversationRow(message: $0) }
      + (pendingPrompts[taskID] ?? []).map { prompt in
        ConversationRow(
          message: TranscriptMessage(
            id: prompt.timelineID, role: .user, blocks: [.text(prompt.text, id: "prompt")]),
          pendingPrompt: prompt
        )
      }
  }
}
