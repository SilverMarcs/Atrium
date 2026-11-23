import SwiftUI

/// An agent's reply. One chip above its text counts every tool call folded
/// behind it. While it's being written, all notes stay in the timeline.
/// Once finished, only its closing text stays and every step before it folds.
/// The chip only opens when there is
/// folded text to read or an agent reported back. Pages the agent showed sit
/// between the chip and the text. Once finished, Copy and Fork sit below it.
struct AssistantMessageView: View {
    let blocks: [TranscriptBlock]
    let isStreaming: Bool
    /// Forks the chat through this reply; nil where it can't be forked.
    var fork: (() -> Void)?
    @Environment(\.earlierPageIDs) private var earlierPageIDs
    #if os(macOS)
    /// Written here, read only by the actions, so hovering doesn't redraw the reply.
    @State private var hover = ReplyHover()
    #endif

    var body: some View {
        let reply = AssistantReply(blocks: blocks, isStreaming: isStreaming)
        VStack(alignment: .leading, spacing: 10) {
            // One chip for both states, so steps opened mid-turn stay open as it ends.
            if reply.hasStepsToRead {
                AssistantStepsButton(steps: reply.steps)
            } else if reply.toolCount > 0 {
                ToolGroupBadge(count: reply.toolCount)
            }
            ForEach(reply.pages) { block in
                if let page = block.page {
                    ChatPageView(page: page, id: block.id, isEarlierVersion: earlierPageIDs.contains(block.id))
                }
            }
            // The shown notes read as one document, so they select together.
            if let text = reply.text {
                MarkdownText(text: text)
            }
            if !isStreaming, reply.text != nil || fork != nil {
                #if os(macOS)
                ReplyActions(text: reply.text, fork: fork, hover: hover)
                #else
                ReplyActions(text: reply.text, fork: fork)
                #endif
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        .contentShape(.rect)
        .onHover { [hover] in hover.isHovered = $0 }
        #endif
        #if os(iOS)
        .animation(.default, value: isStreaming)
        #endif
    }
}
