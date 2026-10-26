import Foundation

nonisolated struct TranscriptBlock: Codable, Sendable, Hashable, Identifiable {
    enum Kind: String, Codable, Sendable {
        /// Markdown written by the user or the agent.
        case text
        /// A tool the agent ran; `text` is a one-line summary such as the command or file.
        case tool
    }

    var id: String
    var kind: Kind
    var text: String
    /// The tool's name, such as "Bash" or "Edit", for tool blocks.
    var toolName: String?

    static func text(_ text: String, id: String) -> TranscriptBlock {
        TranscriptBlock(id: id, kind: .text, text: text)
    }

    static func tool(_ name: String, summary: String, id: String) -> TranscriptBlock {
        TranscriptBlock(id: id, kind: .tool, text: summary, toolName: name)
    }
}
