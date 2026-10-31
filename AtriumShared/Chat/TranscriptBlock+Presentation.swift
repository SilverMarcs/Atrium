import AtriumProtocol
import Foundation

extension TranscriptBlock {
    var symbolName: String {
        if text != nil { "text.alignleft" } else if reporter != nil { "arrowshape.turn.up.backward" } else { "wrench.and.screwdriver" }
    }

    /// What a step reads as when it isn't the agent's own note.
    var stepTitle: String {
        text ?? reporter.map { "\($0.name) reported back" } ?? Self.toolCalls(toolCount)
    }

    static func toolCalls(_ count: Int) -> String {
        count == 1 ? "1 tool call" : "\(count) tool calls"
    }
}
