import SwiftUI

/// The user's prompt as a right-aligned bubble.
struct UserMessageView: View {
    let text: String
    /// Finds the flight that brings this bubble in from the composer, if it
    /// was just sent.
    let sendFlight: (PromptSendAnimator) -> PromptSendFlight?

    var body: some View {
        Text(text)
            .padding(12)
            .background(.background.secondary)
            .clipShape(.rect(cornerRadius: 20))
            // The bubble itself flies, so it measures where the bubble lands
            // rather than the full-width row.
            .modifier(PromptSendEffect(flight: sendFlight))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 60)
            .textSelection(.enabled)
    }
}
