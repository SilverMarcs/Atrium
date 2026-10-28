import SwiftUI

/// Both clients show delivery and retry in the same bubble that later gets confirmed.
struct PendingPromptRow: View {
    let prompt: PendingPrompt
    let retry: () -> Void
    var sendFlight: (PromptSendAnimator) -> PromptSendFlight? = { _ in nil }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            UserMessageView(text: prompt.text, images: prompt.images, sendFlight: sendFlight)
            if prompt.state == .failed {
                if let error = prompt.failureMessage { Text(error).font(.caption).foregroundStyle(.red) }
                Button("Retry", systemImage: "arrow.clockwise", action: retry)
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .tint(.red)
            }
        }
    }
}
