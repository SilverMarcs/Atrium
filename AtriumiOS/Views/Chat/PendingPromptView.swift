import SwiftUI

struct PendingPromptView: View {
    @Environment(CompanionClient.self) private var client
    let prompt: PendingPrompt
    let taskID: String

    var body: some View {
        PendingPromptRow(
            prompt: prompt,
            retry: { client.retryPrompt(prompt.id, in: taskID) },
            sendFlight: { [id = prompt.id] in $0.flight(forPending: id) }
        )
    }
}
