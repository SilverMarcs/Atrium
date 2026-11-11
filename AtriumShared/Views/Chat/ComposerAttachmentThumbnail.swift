import SwiftUI

/// One attached image above the composer, with a button to remove it.
struct ComposerAttachmentThumbnail: View {
    let image: ComposerImage
    let remove: () -> Void

    #if os(macOS)
    private static let size: CGFloat = 80
    #else
    private static let size: CGFloat = 64
    #endif

    var body: some View {
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
        .clipShape(.rect(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            Button("Remove", systemImage: "xmark.circle.fill", action: remove)
                .labelStyle(.iconOnly)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.6))
                .buttonStyle(.plain)
                .padding(4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attached image")
    }
}
