import SwiftUI

/// One quote above the composer, the size of an attached image, which opens
/// its reply when tapped, with a button to remove it.
struct ComposerQuoteThumbnail: View {
    let quote: ComposerQuote
    let open: () -> Void
    let remove: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                // The glyph shares its row with the remove button, so the
                // passage starts below both.
                Image(systemName: "quote.opening")
                    .foregroundStyle(.secondary)
                    .frame(height: 20)
                Text(quote.text)
                    .lineLimit(4)
            }
            .font(.caption2)
            .padding(6)
            .frame(
                width: ComposerAttachmentThumbnail.size,
                height: ComposerAttachmentThumbnail.size,
                alignment: .topLeading
            )
            .background(.fill.tertiary, in: .rect(cornerRadius: ComposerAttachmentThumbnail.cornerRadius))
            .contentShape(.rect(cornerRadius: ComposerAttachmentThumbnail.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quote")
        .accessibilityValue(quote.text)
        .accessibilityHint("Opens your reply")
        .overlay(alignment: .topTrailing) {
            ComposerAttachmentRemoveButton(action: remove)
        }
        .accessibilityElement(children: .contain)
    }
}
