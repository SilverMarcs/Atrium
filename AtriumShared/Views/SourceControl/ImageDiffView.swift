import AtriumProtocol
import SwiftUI

/// An image file's change: the image before and after, side by side.
struct ImageDiffView: View {
    let old: Data?
    let new: Data?
    let kind: GitChangeKind

    var body: some View {
        HStack(spacing: 0) {
            ImageDiffSide(
                image: old.flatMap { Image(data: $0) },
                label: "Before",
                fallback: kind == .added || kind == .untracked ? "New file" : "Not available",
                tint: .red
            )
            Divider()
            ImageDiffSide(
                image: new.flatMap { Image(data: $0) },
                label: "After",
                fallback: kind == .deleted ? "Deleted" : "Not available",
                tint: .green
            )
        }
    }
}

private struct ImageDiffSide: View {
    let image: Image?
    let label: String
    let fallback: String
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.bar)

            Divider()

            if let image {
                ScrollView([.horizontal, .vertical]) {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(tint.opacity(0.05))
            } else {
                ContentUnavailableView {
                    Text(fallback)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
