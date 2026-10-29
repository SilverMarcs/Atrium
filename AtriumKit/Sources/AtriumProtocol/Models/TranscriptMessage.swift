import Foundation

/// One turn of a task's conversation, normalized from each agent's own history
/// so both apps render Claude and Codex the same way.
public nonisolated struct TranscriptMessage: Codable, Sendable, Hashable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public var id: String
    public var role: Role
    /// In the order the agent produced them, so text and tool runs interleave correctly.
    public var blocks: [TranscriptBlock]
    /// Small previews, rather than full image payloads, for local and companion history.
    public var images: [Data]? = nil
    /// Provider-native rewind boundary. Nil for messages that cannot be edited independently.
    public var editTarget: String? = nil
    /// Sent while the agent was working, so it joined that turn rather than starting one.
    public var isSteer: Bool = false

    public init(
        id: String,
        role: Role,
        blocks: [TranscriptBlock],
        images: [Data]? = nil,
        editTarget: String? = nil,
        isSteer: Bool = false
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.images = images
        self.editTarget = editTarget
        self.isSteer = isSteer
    }
}
