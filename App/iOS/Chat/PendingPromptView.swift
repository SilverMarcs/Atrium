import AtriumClient
import AtriumProtocol
import SwiftUI

struct PendingPromptView: View {
    let prompt: PendingPrompt

    var body: some View {
        PendingPromptRow(
            prompt: prompt,
            sendFlight: { [id = prompt.id] in $0.flight(forPending: id) }
        )
    }
}
