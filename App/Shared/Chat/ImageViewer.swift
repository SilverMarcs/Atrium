import SwiftUI
import SwiftMediaViewer

/// Images someone tapped, open in SwiftMediaViewer from the one they tapped.
struct ViewedImages: Identifiable {
    let urls: [URL]
    var startIndex = 0
    /// Keeps a sending prompt's images loadable while they're open.
    var loan: PromptImageLoan?
    let id = UUID()

    init(urls: [URL], startIndex: Int = 0) {
        self.urls = urls
        self.startIndex = startIndex
    }

    /// The images a prompt on its way sends, which live only in memory, lent under `id`.
    init(prompt images: [Data], id: UUID, startIndex: Int) {
        let loan = PromptImageLoan(images, id: id)
        self.init(urls: loan.urls, startIndex: startIndex)
        self.loan = loan
    }

    /// The images attached to a draft, which live only in memory, each lent under its own id.
    init(draft images: [ComposerImage], startIndex: Int) {
        let loan = PromptImageLoan(draft: images)
        self.init(urls: loan.urls, startIndex: startIndex)
        self.loan = loan
    }
}

extension View {
    /// Shows `images` full screen, or in a large sheet on Mac. On iOS it zooms
    /// from the view marked as each image's `matchedTransitionSource` in `namespace`.
    func imageViewer(_ images: Binding<ViewedImages?>, namespace: Namespace.ID) -> some View {
        modifier(ImageViewer(images: images, namespace: namespace))
    }
}

private struct ImageViewer: ViewModifier {
    /// Full screen, or a large sheet on Mac.
    private static let pixelSize = 4096

    @Binding var images: ViewedImages?
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        #if os(macOS)
        content.sheet(item: $images) { images in
            NavigationStack {
                SMVImageModal(urls: images.urls, startIndex: images.startIndex, targetSize: Self.pixelSize,
                              namespace: namespace)
                    .toolbar {
                        ToolbarItem(placement: .close) {
                            Button(role: .close) { self.images = nil }
                        }
                    }
            }
            // As wide as a page, and as tall as the image is at that width.
            .presentationSizing(.page.fitted(horizontal: false, vertical: true))
        }
        #else
        content.fullScreenCover(item: $images) { images in
            SMVImageModal(urls: images.urls, startIndex: images.startIndex, targetSize: Self.pixelSize,
                          namespace: namespace)
        }
        #endif
    }
}
