import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Presents the photo library and the file importer for the composer's
/// attachment menu. The composer shows the images attached so far itself.
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
            .fileImporter(
                isPresented: $composer.isImportingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await composer.attach(contentsOf: urls) }
                case .failure(let error):
                    composer.attachmentError = error.localizedDescription
                }
            }
    }
}

extension View {
    /// Lets the composer's attachment menu pick images.
    func composerAttachmentPickers(_ composer: TaskComposer) -> some View {
        modifier(ComposerAttachmentPickers(composer: composer))
    }
}
