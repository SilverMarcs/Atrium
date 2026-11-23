import SwiftUI

/// The bubble a prompt on its way shows in, which later gets confirmed. One
/// the host doesn't take goes back to the composer.
struct PendingPromptView: View {
    let prompt: PendingPrompt

    var body: some View {
        UserMessageView(text: prompt.text, images: prompt.images, sendFlight: { [id = prompt.id] in $0.flight(forPending: id) })
    }
}
