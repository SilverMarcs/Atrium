import SwiftUI

/// The images attached to the draft, each opening full size when tapped, with
/// a button to remove it.
struct ComposerAttachmentStrip: View {
    let composer: TaskComposer
    /// Where the first image starts, to line it up with the prompt field
    /// below; nil keeps the standard margins.
    var leadingInset: CGFloat?

    @State private var viewedImages: ViewedImages?
    @Namespace private var namespace

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(composer.images.enumerated(), id: \.element.id) { index, image in
                    ComposerAttachmentThumbnail(image: image) {
                        viewedImages = ViewedImages(draft: composer.images, startIndex: index)
                    } remove: {
                        withAnimation { composer.remove(image) }
                    }
                    #if os(iOS)
                    .modifier(ComposerAttachmentZoomSource(image: image, namespace: namespace))
                    #endif
                }
            }
            .padding(leadingInset == nil ? .horizontal : .trailing)
        }
        .contentMargins(.leading, leadingInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .padding(.vertical, 8)
        .imageViewer($viewedImages, namespace: namespace)
    }
}

#if os(iOS)
/// Lets the viewer zoom out of the thumbnail an image is attached as.
private struct ComposerAttachmentZoomSource: ViewModifier {
    let image: ComposerImage
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if let url = PromptImageLoan.url(of: image) {
            content.matchedTransitionSource(id: url, in: namespace) {
                $0.clipShape(.rect(cornerRadius: ComposerAttachmentThumbnail.cornerRadius))
            }
        } else {
            content
        }
    }
}
#endif
