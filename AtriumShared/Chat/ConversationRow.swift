/// A stable timeline row before and after a locally sent prompt is confirmed.
struct ConversationRow: Identifiable {
  let message: TranscriptMessage
  var pendingPrompt: PendingPrompt?

  var id: String { message.id }
}
