import SwiftUI

/// An agent's reply. While it's being written, its notes and tool runs appear as
/// they arrive. Once finished, only its closing text stays in the timeline and
/// every step before it folds into one row above it.
struct AssistantMessageView: View {
    let blocks: [TranscriptBlock]
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isStreaming {
                ForEach(TranscriptRun.runs(in: blocks)) { run in
                    switch run.content {
                    case .text(let text):
                        MarkdownText(text: text)
                    case .tools(let tools):
                        ToolGroupBadge(tools: tools)
                    }
                }
            } else {
                let reply = AssistantReply(blocks: blocks)
                if !reply.steps.isEmpty {
                    AssistantStepsButton(steps: reply.steps)
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
