import PhotosUI
import SwiftUI

/// Presents the photo library and camera for the composer's attachment menu,
/// and on iPhone shows the images attached so far above the composer. The
/// iPad's inline input bar shows them itself.
struct ComposerAttachmentPickers: ViewModifier {
    @Bindable var composer: TaskComposer
    @State private var selection: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if UIDevice.current.userInterfaceIdiom == .phone, !composer.images.isEmpty {
                    ComposerAttachmentStrip(composer: composer)
                }
            }
            .photosPicker(
                isPresented: $composer.isPickingPhotos,
                selection: $selection,
                maxSelectionCount: max(composer.remainingImageSlots, 1),
                matching: .images
            )
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                selection = []
                Task { await attach(items) }
            }
            .fullScreenCover(isPresented: $composer.isTakingPhoto) {
                CameraPicker { data in
                    Task { await composer.attach([data]) }
                }
                .ignoresSafeArea()
            }
    }

    private func attach(_ items: [PhotosPickerItem]) async {
        var sources: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) { sources.append(data) }
        }
        await composer.attach(sources)
    }
}

extension View {
    /// Lets the composer's attachment menu pick images, and shows them.
    func composerAttachmentPickers(_ composer: TaskComposer) -> some View {
        modifier(ComposerAttachmentPickers(composer: composer))
    }
}
