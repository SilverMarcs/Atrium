import SwiftUI

/// An agent's reply. While it's being written, one chip counts all tool calls
/// above the notes as they arrive. Once finished, only its closing text stays in the timeline and
/// every step before it folds into one row above it. The row only opens when
/// there is intermediary text to read.
struct AssistantMessageView: View {
    let blocks: [TranscriptBlock]
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isStreaming {
                let toolCount = blocks.reduce(0) { $0 + $1.toolCount }
                if toolCount > 0 {
                    ToolGroupBadge(count: toolCount)
                }
                ForEach(TranscriptRun.runs(in: blocks)) { run in
                    if case .text(let text) = run.content {
                        MarkdownText(text: text)
                    }
                }
            } else {
                let reply = AssistantReply(blocks: blocks)
                if !reply.steps.isEmpty {
                    if reply.hasIntermediaryText {
                        AssistantStepsButton(steps: reply.steps)
                    } else {
                        ToolGroupBadge(count: reply.steps.reduce(0) { $0 + $1.toolCount })
                    }
                }
                if let text = reply.finalText {
                    MarkdownText(text: text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS)
        .animation(.default, value: isStreaming)
        #endif
    }
}
