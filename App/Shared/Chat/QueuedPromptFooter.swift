import SwiftUI

/// Under a queued prompt's bubble: a clock saying it waits for the agent's
/// turn to end, and Edit, which takes it back into the composer. Another
/// agent's has no Edit: only that agent can change it.
struct QueuedPromptFooter: View {
    let edit: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
                .help("Sends when the agent’s turn ends")
                .accessibilityLabel("Queued")
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
