import SwiftUI

/// One attached image above the composer, which opens full size when
/// tapped, with a button to remove it.
struct ComposerAttachmentThumbnail: View {
    static let cornerRadius: CGFloat = 12

    let image: ComposerImage
    let open: () -> Void
    let remove: () -> Void

    #if os(macOS)
    private static let size: CGFloat = 80
    #else
    private static let size: CGFloat = 64
    #endif

    var body: some View {
        Button(action: open) {
            Group {
                if let thumbnail = Image(data: image.data) {
                    thumbnail
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.secondary
                }
            }
            .frame(width: Self.size, height: Self.size)
            .clipShape(.rect(cornerRadius: Self.cornerRadius))
            .contentShape(.rect(cornerRadius: Self.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attached image")
        .accessibilityHint("Opens the image full size")
        .overlay(alignment: .topTrailing) {
            Button("Remove", systemImage: "xmark.circle.fill", action: remove)
                .labelStyle(.iconOnly)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.6))
                .buttonStyle(.plain)
                .padding(4)
        }
        .accessibilityElement(children: .contain)
    }
}
