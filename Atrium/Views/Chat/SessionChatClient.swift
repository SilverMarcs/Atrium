import Foundation
import Observation

/// A thin local adapter around the same conversation store used on companions.
@MainActor
@Observable
final class SessionChatClient {
  private(set) var feed: CompanionTranscriptFeed?
  private(set) var conversation = ConversationStore()
  private(set) var taskID = ""
  var actionError: String?
  var isPinned = true
  @ObservationIgnored private var subscription: HostTranscriptSubscription?
  @ObservationIgnored private var transport: LocalConversationTransport?
  @ObservationIgnored private weak var integrations: AgentIntegrationStore?

  var pendingPrompts: [PendingPrompt] { conversation.pendingPrompts[taskID] ?? [] }
  var isSending: Bool { conversation.isSending(in: taskID) }

  func start(
    session: TaskSession, integrations: AgentIntegrationStore, sessions: TaskSessionController,
    workspaces: WorkspaceStore
  ) {
    stop()
    taskID = session.id
    conversation = session.conversation
    self.integrations = integrations
    let state = conversation
    let id = session.id
    let subscription = integrations.acquireTranscriptFeed(taskID: id) { [weak state] messages in
      state?.transcripts[id] = messages
      state?.reconcile(taskID: id)
    }
    self.subscription = subscription
    feed = subscription.feed
    if let messages = feed?.messages {
      state.transcripts[id] = messages
      state.reconcile(taskID: id)
    }
    transport = LocalConversationTransport(
      service: CompanionTaskService(
        integrations: integrations, sessions: sessions, workspaces: workspaces),
      feed: feed
    )
    conversation.noteStatus(session.thread.status, for: id)
  }

  func stop() {
    subscription?.release()
    subscription = nil
    feed = nil
  }

  func send(session: TaskSession, willSend: (PendingPrompt) -> Void = { _ in }) {
    let text = session.chatPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard transport != nil, !text.isEmpty || !session.chatImages.isEmpty, !isSending else { return }
    let prompt = conversation.enqueue(text, images: session.chatImages.map(\.data), to: taskID)
    willSend(prompt)
    session.chatPrompt = ""
    session.chatImages = []
    actionError = nil
    isPinned = true
    deliver(prompt.id)
  }

  func retry(_ id: UUID) {
    conversation.prepareRetry(id, in: taskID)
    deliver(id)
  }

  private func deliver(_ id: UUID) {
    guard let transport else { return }
    let taskID = taskID
    conversation.deliver(id, to: taskID, using: transport) { [weak integrations] in
      integrations?.threads.first { $0.id == taskID }?.status
    }
  }

  func interrupt(taskID: String) {
    guard let transport else { return }
    Task {
      do { try await transport.interruptConversation(taskID: taskID) } catch {
        actionError = error.localizedDescription
      }
    }
  }
}
