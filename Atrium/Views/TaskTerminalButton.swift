import AtriumClient
import AtriumProtocol
import SwiftUI

/// Opens a task's conversation in this Mac's terminal app, attached to the
/// same session the chat shows, which carries on here too.
struct TaskTerminalButton: View {
    let item: HostTask
    @State private var isOpening = false

    var body: some View {
        Button("Open in Terminal", systemImage: "terminal") {
            isOpening = true
            Task {
                await item.host.perform(.task(id: item.task.id, action: .openTerminal))
                isOpening = false
            }
        }
        .disabled(isOpening)
        .help("Continue this chat in your terminal app")
    }
}
