import AtriumProtocol
import Foundation
import Observation

/// Transport-independent conversation state, shared by local and companion clients.
@MainActor
@Observable
public final class ConversationStore {
  // Per task, so a chat only updates for its own task's changes.
  public let transcripts = KeyedState<[TranscriptMessage]>()
  public let pendingPrompts = KeyedState<[PendingPrompt]>()
  public let tasksAwaitingAgent = KeyedState<UUID>()
  @ObservationIgnored private var deliveries: [UUID: Task<Void, Never>] = [:]
  /// Takes a prompt that couldn't be sent back to its task's composer, with why.
  @ObservationIgnored var onReturn: ((_ prompt: PendingPrompt, _ taskID: String, _ reason: String?) -> Void)?
  private let confirmedRowIDs = KeyedState<[String: String]>()
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

  /// One prompt's delivery lifecycle. Expiry is a delivery deadline,
  /// independent of the view's lifetime or animation timing.
  func deliver(
    _ id: UUID, to taskID: String,
    using send: @escaping @MainActor (PendingPrompt) async throws -> Void,
    status: @escaping @MainActor () -> AgentThreadStatus?
  ) {
    guard deliveries[id] == nil,
      let prompt = pendingPrompts[taskID]?.first(where: { $0.id == id }),
      prompt.state == .sending
    else { return }
    tasksAwaitingAgent[taskID] = id
    deliveries[id] = Task { [weak self] in
      do {
        try await send(prompt)
        guard let self, !Task.isCancelled else { return }
        self.update(id, in: taskID) { $0.state = .sent }
        try await self.awaitTranscript(id, in: taskID, status: status)
      } catch {
        if !Task.isCancelled {
          self?.giveBack(id, in: taskID, reason: error.localizedDescription)
        }
      }
      self?.deliveries[id] = nil
    }
  }

  /// Gives a sent prompt a while to show in the transcript. One the agent
  /// hasn't taken by then stays while it works, and goes once it stops.
  private func awaitTranscript(
    _ id: UUID, in taskID: String, status: @escaping @MainActor () -> AgentThreadStatus?
  ) async throws {
    try await Task.sleep(for: acknowledgementTimeout)
    guard !Task.isCancelled else { return }
    if status() == .processing {
      update(id, in: taskID) { $0.isOverdue = true }
    } else {
      pendingPrompts[taskID]?.removeAll { $0.id == id && $0.state == .sent }
    }
    stopAwaitingAgent(for: taskID, after: id)
  }

  /// Shows a queued prompt the host is sending as a prompt on its way, in the
  /// same row, until the transcript shows it.
  func adopt(_ queued: QueuedPrompt, in taskID: String, status: @escaping @MainActor () -> AgentThreadStatus?) {
    guard pendingPrompts[taskID]?.contains(where: { $0.id == queued.id }) != true else { return }
    let prompt = PendingPrompt(
      id: queued.id, text: queued.text, images: queued.images, state: .sent,
      anchorUserMessageID: newestUserMessageID(in: taskID),
      expectedUserMessagesAfterAnchor: nextExpectedUserMessageCount(for: taskID)
    )
    pendingPrompts[taskID, default: []].append(prompt)
    tasksAwaitingAgent[taskID] = prompt.id
    deliveries[prompt.id] = Task { [weak self] in
      try? await self?.awaitTranscript(prompt.id, in: taskID, status: status)
      self?.deliveries[prompt.id] = nil
    }
  }

  /// The host put back a queued prompt it couldn't send, which shows as queued again.
  func dropAdopted(_ id: UUID, in taskID: String) {
    deliveries.removeValue(forKey: id)?.cancel()
    pendingPrompts[taskID]?.removeAll { $0.id == id }
    stopAwaitingAgent(for: taskID, after: id)
  }

  func update(_ id: UUID, in taskID: String, _ update: (inout PendingPrompt) -> Void) {
    guard var prompts = pendingPrompts[taskID],
      let index = prompts.firstIndex(where: { $0.id == id })
    else { return }
    update(&prompts[index])
    pendingPrompts[taskID] = prompts
  }

  /// Takes a prompt that couldn't be sent out of the timeline and hands it
  /// back to be sent again from the composer.
  func giveBack(_ id: UUID, in taskID: String, reason: String? = nil) {
    guard var prompts = pendingPrompts[taskID],
      let index = prompts.firstIndex(where: { $0.id == id })
    else { return }
    let prompt = prompts.remove(at: index)
    for later in prompts.indices.dropFirst(index) {
      prompts[later].expectedUserMessagesAfterAnchor -= 1
    }
    pendingPrompts[taskID] = prompts.isEmpty ? nil : prompts
    stopAwaitingAgent(for: taskID, after: id)
    onReturn?(prompt, taskID, reason)
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
    if status != .processing, pendingPrompts[taskID]?.contains(where: { $0.isOverdue && $0.state == .sent }) == true {
      pendingPrompts[taskID]?.removeAll { $0.isOverdue && $0.state == .sent }
    }
  }

  public func footerStatus(for taskID: String, status: AgentThreadStatus) -> AgentThreadStatus {
    if tasksAwaitingAgent[taskID] != nil && status != .waiting { return .processing }
    // A provider may report worker startup as processing before any turn exists.
    if status == .processing, transcripts[taskID]?.isEmpty != false,
       pendingPrompts[taskID]?.isEmpty != false { return .idle }
    return status
  }

  /// Recognizes prompts by their position after an anchor, including image-only
  /// prompts and providers that normalize the text stored in their transcripts.
  @discardableResult
  public func reconcile(taskID: String) -> [PromptConfirmation] {
    let messages = transcripts[taskID] ?? []
    let prompts = pendingPrompts[taskID] ?? []
    var confirmations: [PromptConfirmation] = []
    for prompt in prompts {
      guard let message = messages.prompt(prompt.expectedUserMessagesAfterAnchor, after: prompt.anchorUserMessageID)
      else { continue }
      confirmations.append(PromptConfirmation(promptID: prompt.id, messageID: message.id))
      confirmedRowIDs[taskID, default: [:]][message.id] = prompt.timelineID
    }
    // Each write updates the chat showing this task, so only write what changed.
    if !confirmations.isEmpty {
      let confirmed = Set(confirmations.map(\.promptID))
      pendingPrompts[taskID]?.removeAll { confirmed.contains($0.id) }
    }
    if pendingPrompts[taskID]?.isEmpty == true { pendingPrompts[taskID] = nil }
    if let rowIDs = confirmedRowIDs[taskID] {
      let currentIDs = Set(messages.map(\.id))
      let kept = rowIDs.filter { currentIDs.contains($0.key) }
      if kept.count != rowIDs.count { confirmedRowIDs[taskID] = kept }
    }
    return confirmations
  }

  public func displayMessages(for taskID: String) -> [TranscriptMessage] {
    let rowIDs = confirmedRowIDs[taskID] ?? [:]
    return (transcripts[taskID] ?? []).map { message in
      var message = message
      message.id = rowIDs[message.id] ?? message.id
      return message
    }
  }

  public func containsTimelineID(_ id: String, in taskID: String) -> Bool {
    pendingPrompts[taskID]?.contains { $0.timelineID == id } == true
      || transcripts[taskID]?.contains { $0.id == id } == true
      || confirmedRowIDs[taskID]?.values.contains(id) == true
  }

  func reset() {
    for task in deliveries.values { task.cancel() }
    deliveries = [:]
    transcripts.removeAll()
    pendingPrompts.removeAll()
    tasksAwaitingAgent.removeAll()
    confirmedRowIDs.removeAll()
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
    transcripts[taskID]?.promptAnchor
  }

  private func nextExpectedUserMessageCount(for taskID: String) -> Int {
    (pendingPrompts[taskID]?.count ?? 0) + 1
  }
}
