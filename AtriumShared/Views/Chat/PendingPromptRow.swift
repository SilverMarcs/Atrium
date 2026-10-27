import SwiftUI

/// Both clients show delivery and retry in the same bubble that later gets confirmed.
struct PendingPromptRow: View {
    let prompt: PendingPrompt
    let retry: () -> Void
    var sendFlight: (PromptSendAnimator) -> PromptSendFlight? = { _ in nil }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !prompt.images.isEmpty {
                HStack {
                    ForEach(prompt.images.indices, id: \.self) { index in
                        PromptImageThumbnail(data: prompt.images[index])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !prompt.text.isEmpty {
                UserMessageView(text: prompt.text, sendFlight: sendFlight)
            }
            if prompt.state == .failed {
                Button("Retry", systemImage: "arrow.clockwise", action: retry)
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .tint(.red)
            }
        }
    }
}
