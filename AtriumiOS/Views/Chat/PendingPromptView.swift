import SwiftUI

/// A prompt sent from this phone that the transcript doesn't show yet, drawn
/// like any other prompt, with a small retry button if it didn't get there.
struct PendingPromptView: View {
    @Environment(CompanionClient.self) private var client
    let prompt: PendingPrompt
    let taskID: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !prompt.images.isEmpty {
                PendingPromptImages(images: prompt.images)
            }
            if !prompt.text.isEmpty {
                UserMessageView(text: prompt.text, sendFlight: { [id = prompt.id] in $0.flight(forPending: id) })
            }
            if prompt.state == .failed {
                Button("Retry", systemImage: "arrow.clockwise") {
                    client.retryPrompt(prompt.id, in: taskID)
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .tint(.red)
            }
        }
    }
}
