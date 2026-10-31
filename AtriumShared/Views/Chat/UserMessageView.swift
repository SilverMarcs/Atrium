import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Shared prompt bubble; only padding, desktop copy, and the mobile flight differ.
/// A prompt another agent wrote is gray rather than tinted, so the user's own stand out.
struct UserMessageView: View {
    let text: String
    var images: [Data] = []
    var isFromAgent = false
    var edit: (() -> Void)?
    var editEnabled = true
    var sendFlight: (PromptSendAnimator) -> PromptSendFlight? = { _ in nil }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack {
                    ForEach(images.enumerated(), id: \.offset) { _, data in PromptImageThumbnail(data: data) }
                }
                .contextMenu { PromptContextMenu(text: text, edit: edit, editEnabled: editEnabled) }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !text.isEmpty {
                ExpandableText(text: text)
                #if os(macOS)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                #else
                .padding(12)
                #endif
                .background(isFromAgent ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(Color.accentColor.quinary))
                .clipShape(.rect(cornerRadius: 20))
                // Menu sits on the bubble itself so iOS lifts just the bubble, not the full-width row.
                #if os(iOS)
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 20))
                #endif
                .contextMenu { PromptContextMenu(text: text, edit: edit, editEnabled: editEnabled) }
                .modifier(PromptSendEffect(flight: sendFlight))
                .frame(maxWidth: .infinity, alignment: .trailing)
                #if os(macOS)
                .padding(.leading, 160)
                #else
                .padding(.leading, 60)
                #endif
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .textSelection(.enabled)
    }
}

private struct PromptContextMenu: View {
    let text: String
    let edit: (() -> Void)?
    let editEnabled: Bool

    var body: some View {
        if let edit {
            Button("Edit", systemImage: "pencil", action: edit)
                .disabled(!editEnabled)
        }
        if !text.isEmpty {
            Button("Copy", systemImage: "doc.on.doc") {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                #else
                UIPasteboard.general.string = text
                #endif
            }
        }
    }
}
