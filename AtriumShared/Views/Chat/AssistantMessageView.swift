import AtriumProtocol
import SwiftUI

/// An agent's reply. One chip above its text counts every tool call folded
/// behind it. While it's being written, the latest notes stay in the timeline
/// and older ones fold into the chip. Once finished, only its closing text
/// stays and every step before it folds. The chip only opens when there is
/// folded text to read. Pages the agent showed sit between the chip and the text.
struct AssistantMessageView: View {
    let blocks: [TranscriptBlock]
    let isStreaming: Bool

    var body: some View {
        let reply = AssistantReply(blocks: blocks, isStreaming: isStreaming)
        VStack(alignment: .leading, spacing: 10) {
            // One chip for both states, so steps opened mid-turn stay open as it ends.
            if reply.hasIntermediaryText {
                AssistantStepsButton(steps: reply.steps)
            } else if reply.toolCount > 0 {
                ToolGroupBadge(count: reply.toolCount)
            }
            ForEach(reply.pages) { block in
                if let page = block.page {
                    ChatPageView(page: page)
                }
            }
            // The shown notes read as one document, so they select together.
            if let text = reply.text {
                MarkdownText(text: text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS)
        .animation(.default, value: isStreaming)
        #endif
    }
}
