import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImageDropHandler: ViewModifier {
    @Bindable var chat: Chat
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.image, .fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
            // .overlay {
                // if isTargeted {
                    // RoundedRectangle(cornerRadius: 12)
                        // .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        // .padding(6)
                        // .allowsHitTesting(false)
                // }
            // }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                    guard let url else { return }
                    if let attachment = AttachmentLoader.load(url: url) {
                        Task { @MainActor in
                            chat.pendingAttachments.append(attachment)
                        }
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data,
                          let attachment = AttachmentLoader.make(data: data, type: .image, fileName: "dropped.png")
                    else { return }
                    Task { @MainActor in
                        chat.pendingAttachments.append(attachment)
                    }
                }
            }
        }
        return handled
    }
}

extension View {
    func imageDropHandler(chat: Chat) -> some View {
        modifier(ImageDropHandler(chat: chat))
    }
}
