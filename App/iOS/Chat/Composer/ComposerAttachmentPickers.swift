import PhotosUI
import SwiftUI

/// Presents the photo library and camera for the composer's attachment menu.
/// The composers show the images attached so far themselves.
struct ComposerAttachmentPickers: ViewModifier {
    @Bindable var composer: TaskComposer
    @State private var selection: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: $composer.isPickingPhotos,
                selection: $selection,
                maxSelectionCount: max(composer.remainingImageSlots, 1),
                matching: .images
            )
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                selection = []
                Task { await composer.attach(items) }
            }
            .fullScreenCover(isPresented: $composer.isTakingPhoto) {
                CameraPicker { data in
                    Task { await composer.attach([data]) }
                }
                .ignoresSafeArea()
            }
    }
}

extension View {
    /// Lets the composer's attachment menu pick images.
    func composerAttachmentPickers(_ composer: TaskComposer) -> some View {
        modifier(ComposerAttachmentPickers(composer: composer))
    }
}
