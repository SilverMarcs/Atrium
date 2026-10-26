import SwiftUI

/// A prompt sent from this phone that the transcript doesn't show yet: faded
/// while it's on its way, with a small retry button if it didn't get there.
struct PendingPromptView: View {
    @Environment(CompanionClient.self) private var client
    let prompt: PendingPrompt
    let taskID: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Group {
                if !prompt.images.isEmpty {
                    PendingPromptImages(images: prompt.images)
                }
                if !prompt.text.isEmpty {
                    UserMessageView(text: prompt.text)
                }
            }
            .opacity(prompt.state == .sending ? 0.6 : 1)

            if prompt.state == .failed {
                Button("Retry", systemImage: "arrow.clockwise") {
                    client.retryPrompt(prompt.id, in: taskID)
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .tint(.red)
            }
        }
        .animation(.default, value: prompt.state)
    }
}
