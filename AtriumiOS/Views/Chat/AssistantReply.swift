import Foundation

/// Splits a reply into its closing text, the text written after the last tool
/// call, and the steps before it. While the agent is still working, its latest
/// text stands in for the reply.
struct AssistantReply {
    let steps: [TranscriptBlock]
    let finalText: String?

    init(blocks: [TranscriptBlock]) {
        let trailingText = blocks.reversed().prefix { $0.kind == .text }
        if trailingText.isEmpty {
            steps = blocks
            finalText = nil
        } else {
            steps = Array(blocks.dropLast(trailingText.count))
            finalText = trailingText.reversed().map(\.text).joined(separator: "\n\n")
        }
    }
}
