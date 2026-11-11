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
            Button("Camera", systemImage: "camera") {
                composer.isTakingPhoto = true
            }
            .disabled(!CameraPicker.isAvailable)
        } label: {
            label
        }
        .menuIndicator(.hidden)
        .disabled(composer.remainingImageSlots == 0)
    }
}

extension ComposerAttachmentMenu where MenuLabel == Label<Text, Image> {
    /// The menu as a toolbar button.
    init() {
        self.init { Label("Attach", systemImage: "plus") }
    }
}
