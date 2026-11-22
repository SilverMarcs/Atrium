import AtriumClient
import AtriumProtocol
import SwiftUI

/// Attaches images to the prompt, beside the composer, and brings back
/// drafts from the project's scratchpad. The pickers it opens are presented
/// by `ComposerAttachmentPickers`.
struct ComposerAttachmentMenu<MenuLabel: View>: View {
    @Environment(TaskComposer.self) private var composer

    let item: HostTask?
    @ViewBuilder let label: MenuLabel

    var body: some View {
        Menu {
            Group {
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
            }
            .disabled(composer.remainingImageSlots == 0)
            if let item, !item.scratchpad.isEmpty {
                Divider()
                Menu {
                    ForEach(item.scratchpad) { draft in
                        Button {
                            composer.restore(draft, from: item)
                        } label: {
                            Label(draft.title, systemImage: draft.hasText ? "text.alignleft" : "photo")
                            if let summary = draft.imageSummary { Text(summary) }
                        }
                    }
                } label: {
                    Label("Scratchpad", systemImage: "note.text")
                    Text(item.scratchpad.count == 1 ? "1 draft" : "\(item.scratchpad.count) drafts")
                }
            }
        } label: {
            label
        }
        #if os(macOS)
        .menuStyle(.button)
        #endif
        .menuIndicator(.hidden)
    }
}
