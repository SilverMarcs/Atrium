import Foundation

extension TranscriptBlock {
    var symbolName: String { text == nil ? "wrench.and.screwdriver" : "text.alignleft" }

    static func toolCalls(_ count: Int) -> String {
        count == 1 ? "1 tool call" : "\(count) tool calls"
    }
}
