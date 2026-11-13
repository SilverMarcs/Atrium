import SwiftUI

/// Attaches images to the prompt, beside the composer. The pickers it opens
/// are presented by `ComposerAttachmentPickers`.
struct ComposerAttachmentMenu<MenuLabel: View>: View {
    @Environment(TaskComposer.self) private var composer

    @ViewBuilder let label: MenuLabel

    var body: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") {
                composer.isPickingPhotos = true
            }
            #if os(iOS)
            Button("Camera", systemImage: "camera") {
                composer.isTakingPhoto = true
            }
            .disabled(!CameraPicker.isAvailable)
            #else
            Divider()
            Button("Attach Images", systemImage: "paperclip") {
                composer.isImportingFiles = true
            }
            #endif
        } label: {
            label
        }
        #if os(macOS)
        .menuStyle(.button)
        #endif
        .menuIndicator(.hidden)
        .disabled(composer.remainingImageSlots == 0)
    }
}
