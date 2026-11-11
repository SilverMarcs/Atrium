import AtriumProtocol
import Foundation

/// Splits a reply into the text the timeline shows and the steps folded behind
/// it. A finished reply shows its closing text, written after the last tool
/// call, report or page, even when reports came in after it. A running one
/// shows all its notes. Pages the agent showed never fold: they stay above
/// the text, where the agent was told they appear.
struct AssistantReply {
    /// Every other block, in order, with tool calls between hidden notes counted together.
    let steps: [TranscriptBlock]
    /// The shown notes as one document.
    let text: String?
    /// Every page the agent showed, in order.
    let pages: [TranscriptBlock]

    /// Whether the steps hold more than counted tool calls: folded notes, or
    /// agents that reported back.
    var hasStepsToRead: Bool {
        steps.contains { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || $0.reporter != nil }
    }

    var toolCount: Int {
        steps.reduce(0) { $0 + $1.toolCount }
    }

    init(blocks: [TranscriptBlock], isStreaming: Bool) {
        // Reports arriving after the closing text, with nothing written since,
        // such as a subagent's late notice or one sent with the next prompt,
        // fold without hiding it.
        let end = blocks.lastIndex { $0.reporter == nil }.map { $0 + 1 } ?? 0
        let shown: [Int] = if isStreaming {
            blocks.indices.filter { blocks[$0].text != nil }
        } else {
            Array((blocks[..<end].lastIndex { $0.text == nil }.map { $0 + 1 } ?? 0)..<end)
        }
        var steps: [TranscriptBlock] = []
        for index in blocks.indices where !shown.contains(index) && blocks[index].page == nil {
            if case .tools(let count, _) = blocks[index], case .tools(let previous, let id)? = steps.last {
                steps[steps.endIndex - 1] = .tools(count: previous + count, id: id)
            } else {
                steps.append(blocks[index])
            }
        }
        self.steps = steps
        pages = blocks.filter { $0.page != nil }
        let texts = shown.compactMap { blocks[$0].text }
        text = texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }
}
