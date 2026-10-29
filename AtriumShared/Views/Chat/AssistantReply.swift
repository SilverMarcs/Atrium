import AtriumProtocol
import Foundation

/// Splits a reply into the text the timeline shows and the steps folded behind
/// it. A finished reply shows its closing text, written after the last tool
/// call. A running one shows its latest notes, so the work so far stays short.
struct AssistantReply {
    /// How many of a running reply's latest notes stay in the timeline.
    static let runningNoteLimit = 4

    /// Every other block, in order, with tool calls between hidden notes counted together.
    let steps: [TranscriptBlock]
    /// The shown notes as one document.
    let text: String?

    var hasIntermediaryText: Bool {
        steps.contains { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }

    var toolCount: Int {
        steps.reduce(0) { $0 + $1.toolCount }
    }

    init(blocks: [TranscriptBlock], isStreaming: Bool) {
        let shown: [Int] = if isStreaming {
            Array(blocks.indices.filter { blocks[$0].text != nil }.suffix(Self.runningNoteLimit))
        } else {
            Array((blocks.lastIndex { $0.text == nil }.map { $0 + 1 } ?? 0)..<blocks.endIndex)
        }
        var steps: [TranscriptBlock] = []
        for index in blocks.indices where !shown.contains(index) {
            if case .tools(let count, _) = blocks[index], case .tools(let previous, let id)? = steps.last {
                steps[steps.endIndex - 1] = .tools(count: previous + count, id: id)
            } else {
                steps.append(blocks[index])
            }
        }
        self.steps = steps
        let texts = shown.compactMap { blocks[$0].text }
        text = texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }
}
