import AtriumClient
import AtriumProtocol

/// A stable timeline row before and after a locally sent prompt is confirmed.
struct ConversationRow: Identifiable {
  let message: TranscriptMessage
  var pendingPrompt: PendingPrompt?
  /// The prompt waiting for the agent's turn to end, which keeps this row
  /// once the host sends it.
  var queuedPrompt: QueuedPrompt?

  var id: String { message.id }
}

extension ConversationStore {
  /// The task's messages as laid out by `turns`, then its prompts still on
  /// their way, then the prompt waiting for the turn to end.
  func rows(for taskID: String, turns: ConversationTurns, queued: QueuedPrompt?) -> [ConversationRow] {
    let pending = pendingPrompts[taskID] ?? []
    let waiting = queued.flatMap { queued in
      queued.isSending || pending.contains { $0.id == queued.id } ? nil : queued
    }
    return turns.messages.map { ConversationRow(message: $0) }
      + pending.map { prompt in
        ConversationRow(
          message: TranscriptMessage(
            id: prompt.timelineID, role: .user, blocks: [.text(prompt.text, id: "prompt")]),
          pendingPrompt: prompt
        )
      }
      + (waiting.map { queued in
        [ConversationRow(
          message: TranscriptMessage(
            id: PendingPrompt.timelineID(queued.id), role: .user,
            blocks: queued.text.isEmpty ? [] : [.text(queued.text, id: "prompt")], images: queued.images),
          queuedPrompt: queued
        )]
      } ?? [])
  }
}
