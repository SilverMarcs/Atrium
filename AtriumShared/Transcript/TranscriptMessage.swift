import Foundation

/// One turn of a task's conversation, normalized from each agent's own history
/// so both apps render Claude and Codex the same way.
nonisolated struct TranscriptMessage: Codable, Sendable, Hashable, Identifiable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    var id: String
    var role: Role
    /// In the order the agent produced them, so text and tool runs interleave correctly.
    var blocks: [TranscriptBlock]
    /// Small previews, rather than full image payloads, for local and companion history.
    var images: [Data]? = nil
}
