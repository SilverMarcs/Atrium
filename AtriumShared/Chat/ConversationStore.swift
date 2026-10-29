import Foundation
import Observation

/// Transport-independent conversation state, shared by local and companion clients.
@MainActor
@Observable
final class ConversationStore {
  var transcripts: [String: [TranscriptMessage]] = [:]
  var pendingPrompts: [String: [PendingPrompt]] = [:]
  var tasksAwaitingAgent: [String: UUID] = [:]
  @ObservationIgnored private var deliveries: [UUID: Task<Void, Never>] = [:]
  private var confirmedRowIDs: [String: [String: String]] = [:]
  private let acknowledgementTimeout: Duration

  init(acknowledgementTimeout: Duration = .seconds(20)) {
    self.acknowledgementTimeout = acknowledgementTimeout
  }

  @discardableResult
  func enqueue(_ text: String, images: [Data], to taskID: String, isSteer: Bool = false) -> PendingPrompt {
    let prompt = PendingPrompt(
      text: text, images: images,
      anchorUserMessageID: newestUserMessageID(in: taskID),
      expectedUserMessagesAfterAnchor: nextExpectedUserMessageCount(for: taskID),
      isSteer: isSteer
    )
    pendingPrompts[taskID, default: []].append(prompt)
    tasksAwaitingAgent[taskID] = prompt.id
    return prompt
  }

  func prepareRetry(_ id: UUID, in taskID: String) {
    let anchor = newestUserMessageID(in: taskID)
    let expected = nextExpectedUserMessageCount(for: taskID)
    update(id, in: taskID) {
      $0.state = .sending
      $0.failureMessage = nil
      $0.isOverdue = false
      $0.anchorUserMessageID = anchor
      $0.expectedUserMessagesAfterAnchor = expected
    }
    tasksAwaitingAgent[taskID] = id
  }

  /// One delivery lifecycle for both transports. Expiry is a delivery deadline,
  /// independent of the view's lifetime or animation timing.
  func deliver(
    _ id: UUID, to taskID: String,
    using transport: any ConversationTransport,
    status: @escaping @MainActor () -> AgentThreadStatus?
  ) {
    guard deliveries[id] == nil,
      let prompt = pendingPrompts[taskID]?.first(where: { $0.id == id }),
      prompt.state == .sending
    else { return }
    tasksAwaitingAgent[taskID] = id
    deliveries[id] = Task { [weak self] in
      do {
        try await transport.deliverPrompt(prompt, to: taskID)
        guard let self, !Task.isCancelled else { return }
        self.update(id, in: taskID) { $0.state = .sent }
        try await Task.sleep(for: self.acknowledgementTimeout)
        guard !Task.isCancelled else { return }
        if status() == .processing {
          self.update(id, in: taskID) { $0.isOverdue = true }
        } else {
          self.pendingPrompts[taskID]?.removeAll { $0.id == id && $0.state == .sent }
        }
        self.stopAwaitingAgent(for: taskID, after: id)
      } catch {
        if !Task.isCancelled {
          self?.markFailed(id, in: taskID, message: error.localizedDescription)
          self?.stopAwaitingAgent(for: taskID, after: id)
        }
      }
      self?.deliveries[id] = nil
    }
  }

  func update(_ id: UUID, in taskID: String, _ update: (inout PendingPrompt) -> Void) {
    guard var prompts = pendingPrompts[taskID],
      let index = prompts.firstIndex(where: { $0.id == id })
    else { return }
    update(&prompts[index])
    pendingPrompts[taskID] = prompts
  }

  func markFailed(_ id: UUID, in taskID: String, message: String? = nil) {
    guard var prompts = pendingPrompts[taskID],
      let index = prompts.firstIndex(where: { $0.id == id })
    else { return }
    prompts[index].state = .failed
    prompts[index].failureMessage = message
    for later in prompts.indices.dropFirst(index + 1) where prompts[later].state != .failed {
      prompts[later].expectedUserMessagesAfterAnchor -= 1
    }
    pendingPrompts[taskID] = prompts
  }

  func stopAwaitingAgent(for taskID: String, after id: UUID) {
    if tasksAwaitingAgent[taskID] == id { tasksAwaitingAgent[taskID] = nil }
  }

  /// Only a change of status answers a prompt: the status it was sent at, such
  /// as the last turn's `done`, keeps arriving with unrelated task-list changes
  /// until the agent starts on it.
  func noteStatus(_ status: AgentThreadStatus, previous: AgentThreadStatus?, for taskID: String) {
    if let previous, previous != status, status != .idle {
      tasksAwaitingAgent[taskID] = nil
    }
    if status != .processing {
      pendingPrompts[taskID]?.removeAll { $0.isOverdue && $0.state == .sent }
    }
  }

  func footerStatus(for taskID: String, status: AgentThreadStatus) -> AgentThreadStatus {
    if tasksAwaitingAgent[taskID] != nil && status != .waiting { return .processing }
    // A provider may report worker startup as processing before any turn exists.
    if status == .processing, transcripts[taskID]?.isEmpty != false,
       pendingPrompts[taskID]?.contains(where: { $0.state != .failed }) != true { return .idle }
    return status
  }

  func isSending(in taskID: String) -> Bool {
    pendingPrompts[taskID]?.contains { $0.state == .sending } == true
  }

  /// Recognizes prompts by their position after an anchor, including image-only
  /// prompts and providers that normalize the text stored in their transcripts.
  @discardableResult
  func reconcile(taskID: String) -> [PromptConfirmation] {
    let messages = transcripts[taskID] ?? []
    let prompts = pendingPrompts[taskID] ?? []
    var confirmations: [PromptConfirmation] = []
    for prompt in prompts where prompt.state != .failed {
      let start =
        prompt.anchorUserMessageID.flatMap { id in messages.firstIndex { $0.id == id } }.map {
          $0 + 1
        } ?? 0
      let users = messages[start...].filter { $0.role == .user }
      let position = prompt.expectedUserMessagesAfterAnchor
      guard position > 0, position <= users.count else { continue }
      let message = users[position - 1]
      confirmations.append(PromptConfirmation(promptID: prompt.id, messageID: message.id))
      confirmedRowIDs[taskID, default: [:]][message.id] = prompt.timelineID
    }
    let confirmed = Set(confirmations.map(\.promptID))
    pendingPrompts[taskID]?.removeAll { confirmed.contains($0.id) }
    if pendingPrompts[taskID]?.isEmpty == true { pendingPrompts[taskID] = nil }
    let currentIDs = Set(messages.map(\.id))
    confirmedRowIDs[taskID] = confirmedRowIDs[taskID]?.filter { currentIDs.contains($0.key) }
    return confirmations
  }

  func displayMessages(for taskID: String) -> [TranscriptMessage] {
    let rowIDs = confirmedRowIDs[taskID] ?? [:]
    return (transcripts[taskID] ?? []).map { message in
      var message = message
      message.id = rowIDs[message.id] ?? message.id
      return message
    }
  }

  func containsTimelineID(_ id: String, in taskID: String) -> Bool {
    pendingPrompts[taskID]?.contains { $0.timelineID == id } == true
      || transcripts[taskID]?.contains { $0.id == id } == true
      || confirmedRowIDs[taskID]?.values.contains(id) == true
  }

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

  func reset() {
    for task in deliveries.values { task.cancel() }
    deliveries = [:]
    transcripts = [:]
    pendingPrompts = [:]
    tasksAwaitingAgent = [:]
    confirmedRowIDs = [:]
  }

  func remove(_ taskID: String) {
    for prompt in pendingPrompts[taskID] ?? [] {
      deliveries.removeValue(forKey: prompt.id)?.cancel()
    }
    transcripts[taskID] = nil
    pendingPrompts[taskID] = nil
    tasksAwaitingAgent[taskID] = nil
    confirmedRowIDs[taskID] = nil
  }

  private func newestUserMessageID(in taskID: String) -> String? {
    transcripts[taskID]?.last { $0.role == .user }?.id
  }

  private func nextExpectedUserMessageCount(for taskID: String) -> Int {
    (pendingPrompts[taskID]?.filter { $0.state != .failed }.count ?? 0) + 1
  }
}
