import SwiftUI

/// The label of a menu in the composer's button row: its value in secondary
/// text with a chevron, like a pop-up button without a bezel.
struct ComposerMenuLabel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 5) {
            content
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .imageScale(.small)
                .font(.caption)
                .bold()
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(.capsule)
    }
}
