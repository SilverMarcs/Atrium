#if os(iOS)
import AtriumClient
import SwiftUI

/// The bubble a prompt on its way shows in, which later gets confirmed. One
/// the host doesn't take goes back to the composer.
struct PendingPromptRow: View {
    let prompt: PendingPrompt
    var sendFlight: ((PromptFlights) -> PromptFlight?)?

    var body: some View {
        UserMessageView(text: prompt.text, images: prompt.images, sendFlight: sendFlight)
    }
}
#endif
