import SwiftUI

/// The images attached to the draft, each with a button to remove it.
struct ComposerAttachmentStrip: View {
    let composer: TaskComposer

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(composer.images) { image in
                    ComposerAttachmentThumbnail(image: image) {
                        composer.remove(image)
                    }
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, 8)
    }
}
