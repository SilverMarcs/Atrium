import Foundation

/// The local adapter uses exactly the host actions a companion request uses.
@MainActor
struct LocalConversationTransport: ConversationTransport {
  let service: CompanionTaskService
  weak var feed: CompanionTranscriptFeed?

  func deliverPrompt(_ prompt: PendingPrompt, to taskID: String) async throws {
    let reply = await service.prompt(prompt.text, images: prompt.images, toTask: taskID)
    if case .failed(let message) = reply { throw IntegrationError(message: message) }
    feed?.refresh()
  }

  func interruptConversation(taskID: String) async throws {
    if case .failed(let message) = await service.interrupt(task: taskID) {
      throw IntegrationError(message: message)
    }
  }
}
