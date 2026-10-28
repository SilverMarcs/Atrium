import SwiftUI

/// Red glass cross beside the composer's attachment button while editing a message.
struct ConversationEditCancelButton: View {
    let action: () -> Void

    var body: some View {
        Button("Cancel Edit", systemImage: "xmark.circle.fill") {
            withAnimation { action() }
        }
        .labelStyle(.iconOnly)
        .font(.largeTitle)
        .fontWeight(.semibold)
        .foregroundStyle(.white.opacity(0.7), .clear)
        .glassEffect(.regular.tint(.red.opacity(0.6)))
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Cancel Edit")
        .offset(y: -1)
        .scaleEffect(0.9)
    }
}
