import SwiftUI

/// The images attached to the draft, each with a button to remove it.
struct ComposerAttachmentStrip: View {
    let composer: TaskComposer
    /// Where the first image starts, to line it up with the prompt field
    /// below; nil keeps the standard margins.
    var leadingInset: CGFloat?

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(composer.images) { image in
                    ComposerAttachmentThumbnail(image: image) {
                        withAnimation { composer.remove(image) }
                    }
                }
            }
            .padding(leadingInset == nil ? .horizontal : .trailing)
        }
        .contentMargins(.leading, leadingInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .padding(.vertical, 8)
    }
}
