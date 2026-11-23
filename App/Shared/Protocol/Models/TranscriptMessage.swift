import Foundation

/// One turn of a task's conversation, normalized from each agent's own history
/// so both apps render every provider the same way.
nonisolated struct TranscriptMessage: Codable, Sendable, Hashable, Identifiable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    var id: String
    var role: Role
    /// In the order the agent produced them, so text and tool runs interleave correctly.
    var blocks: [TranscriptBlock]
    /// Small previews, rather than full image payloads, for local and companion
    /// history. `HostRequest.promptImage` fetches each one as it was sent.
    var images: [Data]? = nil
    /// Present a question response as a question and answer within its bubble.
    var questionAnswers: [TranscriptQuestionAnswer]? = nil
    /// Provider-native rewind boundary. Nil for messages that cannot be edited independently.
    var editTarget: String? = nil
    /// Sent while the agent was working, so it joined that turn rather than starting one.
    var isSteer: Bool = false
    /// Set on a user message another agent wrote, rather than the user.
    var relay: TranscriptRelay? = nil

    /// The message's text blocks, one per line.
    var text: String { blocks.compactMap(\.text).joined(separator: "\n") }
}
