/// Delivery is the only distinction between a local chat and a companion chat.
@MainActor
protocol ConversationTransport {
  func deliverPrompt(_ prompt: PendingPrompt, to taskID: String) async throws
  func interruptConversation(taskID: String) async throws
}
