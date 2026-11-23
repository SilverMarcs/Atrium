import Foundation

/// A prompt waiting on its host for the agent's turn to end. A task has at
/// most one: prompts queued while one waits are added to it.
nonisolated struct QueuedPrompt: Codable, Sendable, Hashable, Identifiable {
    /// Also the ID of the prompt's row in a client's timeline, from the
    /// first prompt queued, so its bubble stays the same as more join it
    /// and once it's sent.
    var id: UUID
    var text: String
    /// Small previews of the attached images. `TaskAction.takeQueuedPrompt`
    /// returns them as they were sent.
    var images: [Data]
    /// The host is sending it to the agent, which starts its next turn with it.
    var isSending: Bool
    /// Another session's agent queued it, so only that agent can change it.
    var isFromAgent: Bool

    init(id: UUID, text: String, images: [Data] = [], isSending: Bool = false, isFromAgent: Bool = false) {
        self.id = id
        self.text = text
        self.images = images
        self.isSending = isSending
        self.isFromAgent = isFromAgent
    }

    /// The text of a prompt queued while another waits, added after it.
    static func joined(_ text: String, to waiting: String) -> String {
        [waiting, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
