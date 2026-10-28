import SwiftUI

struct PendingPromptView: View {
    let prompt: PendingPrompt
    let item: HostTask

    var body: some View {
        PendingPromptRow(
            prompt: prompt,
            retry: { item.host.retryPrompt(prompt.id, in: item.task.id) },
            sendFlight: { [id = prompt.id] in $0.flight(forPending: id) }
        )
    }
}
