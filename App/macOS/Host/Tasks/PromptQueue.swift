import AtriumProtocol
import Foundation
import Observation

/// Prompts waiting for their task's turn to end, at most one per task:
/// prompts queued while one waits are added to it, from the same sender.
/// Each goes to its agent once the agent is done; a person's stop hands it
/// back instead. Saved as they change, so a relaunch keeps them. Task lists
/// observe it to show what waits.
@MainActor
@Observable
final class PromptQueue {
    nonisolated struct Entry: Codable, Sendable {
        var id: UUID
        var text: String
        /// JPEG data, as sent.
        var images: [Data]
        /// Small previews of `images`, for task lists.
        var previews: [Data]
        /// The session whose agent queued it, which gets its turn's result;
        /// nil for the user's own.
        var requester: String?

        /// Adds a prompt queued after this one.
        mutating func add(_ text: String, images: [Data]) {
            self.text = QueuedPrompt.joined(text, to: self.text)
            self.images += images
            previews += images.compactMap(TranscriptImage.thumbnail)
        }
    }

    private(set) var entries: [String: Entry] = [:] { didSet { save() } }
    /// Prompts on their way to their agents, by task ID.
    private var sending: [String: Entry] = [:]

    /// Sends a prompt that waited, as its sender would have: the user's
    /// directly, an agent's as a turn that reports back to it.
    @ObservationIgnored var deliver: ((Entry, AgentThread) async throws -> Void)?
    /// Publishes the task list, so clients see a prompt is being sent before
    /// its turn's first event reaches them.
    @ObservationIgnored var onSend: (() -> Void)?
    @ObservationIgnored private let integrations: AgentIntegrationStore
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var isSaveScheduled = false

    /// How long an agent stays done before its prompt goes, so a status
    /// that settles a moment later, or results reported back to it, go first.
    private static let settleDelay: Duration = .seconds(1)

    init(integrations: AgentIntegrationStore, file: URL) {
        self.integrations = integrations
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    /// Queues a prompt for the task, added to any prompt already waiting
    /// from the same sender. One that starts waiting takes `id`.
    /// - Returns: False when a prompt from someone else is waiting.
    func add(_ text: String, images: [Data], to taskID: String, as id: UUID, from requester: String? = nil) -> Bool {
        guard let waiting = entries[taskID] else {
            entries[taskID] = Entry(
                id: id, text: text, images: images, previews: images.compactMap(TranscriptImage.thumbnail), requester: requester)
            return true
        }
        guard waiting.requester == requester else { return false }
        entries[taskID]?.add(text, images: images)
        return true
    }

    /// Removes the task's waiting prompt.
    func take(from taskID: String) -> Entry? {
        entries.removeValue(forKey: taskID)
    }

    /// Returns a prompt taken from the queue, ahead of anything its sender
    /// queued since. Someone else's queued since keeps its place.
    func putBack(_ entry: Entry, to taskID: String) {
        var restored = entry
        if let queued = entries[taskID] {
            guard queued.requester == entry.requester else { return }
            restored.add(queued.text, images: queued.images)
        }
        entries[taskID] = restored
    }

    func remove(_ taskID: String) {
        entries[taskID] = nil
    }

    /// Follows a thread's status: its prompt goes once its agent is done.
    func observe(_ thread: AgentThread) {
        if isReady(thread) { Task { await sendAfterSettling(thread.id) } }
    }

    /// What the task's clients show waiting.
    func queuedPrompt(for taskID: String) -> QueuedPrompt? {
        guard let entry = entries[taskID] ?? sending[taskID] else { return nil }
        return QueuedPrompt(
            id: entry.id, text: entry.text, images: entry.previews,
            isSending: entries[taskID] == nil, isFromAgent: entry.requester != nil)
    }

    private func isReady(_ thread: AgentThread) -> Bool {
        (thread.status == .done || thread.status == .idle) && entries[thread.id] != nil && sending[thread.id] == nil
    }

    private func sendAfterSettling(_ taskID: String) async {
        let id = entries[taskID]?.id
        try? await Task.sleep(for: Self.settleDelay)
        guard let thread = integrations.threads.first(where: { $0.id == taskID }), isReady(thread),
              let entry = entries[taskID], entry.id == id, let deliver else { return }
        entries[taskID] = nil
        sending[taskID] = entry
        onSend?()
        do {
            try await deliver(entry, thread)
        } catch {
            integrations.actionError = error.localizedDescription
            // It waits again, for the next turn to end.
            putBack(entry, to: taskID)
        }
        sending[taskID] = nil
    }

    /// Writes once the current change is through, however much it touched.
    private func save() {
        guard !isSaveScheduled else { return }
        isSaveScheduled = true
        Task {
            isSaveScheduled = false
            guard let data = try? JSONEncoder().encode(entries) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}
