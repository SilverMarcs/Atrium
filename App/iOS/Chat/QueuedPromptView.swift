import AtriumClient
import AtriumProtocol
import SwiftUI

/// The prompt waiting for the agent's turn to end, at the end of the timeline.
struct QueuedPromptView: View {
    let prompt: QueuedPrompt
    let item: HostTask
    @Environment(TaskComposer.self) private var composer

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            UserMessageView(text: prompt.text, images: prompt.images, isFromAgent: prompt.isFromAgent)
            QueuedPromptFooter(edit: prompt.isFromAgent ? nil : { composer.editQueuedPrompt(of: item) })
        }
    }
}
