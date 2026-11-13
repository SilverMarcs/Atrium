import SwiftUI

/// Under a queued prompt's bubble: a clock saying it waits for the agent's
/// turn to end and offers to send it now, and Edit, which takes it back into
/// the composer. Another agent's has neither action: only it can change it.
struct QueuedPromptFooter: View {
    let edit: (() -> Void)?
    let sendNow: (() -> Void)?
    @State private var isConfirmingSend = false

    var body: some View {
        HStack {
            if let sendNow {
                Button("Send Queued Message Now", systemImage: "clock") {
                    isConfirmingSend = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Send queued message now")
                .alert("Send queued message now?", isPresented: $isConfirmingSend) {
                    Button("Send Now", action: sendNow)
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will steer the agent immediately instead of waiting for its turn to end.")
                }
            } else {
                Image(systemName: "clock")
                    .foregroundStyle(.tertiary)
                    .help("Sends when the agent’s turn ends")
                    .accessibilityLabel("Queued")
            }
            if let edit {
                Button("Edit", systemImage: "pencil", action: edit)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Edit")
            }
        }
        .font(.caption)
        .padding(.trailing, 8)
    }
}
