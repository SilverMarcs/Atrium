import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A prompt in the timeline: its images and its bubble. Only padding, desktop
/// copy, and how a just-sent bubble flies in differ by platform.
struct UserMessageView: View {
    let text: String
    var images: [Data] = []
    var isFromAgent = false
    var edit: PromptEdit?
    #if os(macOS)
    /// The timeline row of a prompt sent from here, whose bubble can fly in.
    var flightRowID: String?
    #else
    /// Finds this bubble's flight, if it was just sent. A bubble that can't
    /// have one (nil) skips the effect and never observes flights.
    var sendFlight: ((PromptSendAnimator) -> PromptSendFlight?)?
    #endif

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack {
                    ForEach(images.enumerated(), id: \.offset) { _, data in PromptImageThumbnail(data: data) }
                }
                .contextMenu { PromptContextMenu(text: text, edit: edit) }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !text.isEmpty {
                PromptBubble(text: text, isFromAgent: isFromAgent)
                // Menu sits on the bubble itself so iOS lifts just the bubble, not the full-width row.
                #if os(iOS)
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 20))
                #endif
                .contextMenu { PromptContextMenu(text: text, edit: edit) }
                #if os(macOS)
                .modifier(PromptFlightTarget(rowID: flightRowID))
                #else
                .modifier(PromptSendEffect(flight: sendFlight))
                #endif
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

/// Editing a prompt from its bubble's menu. Whether it's allowed is read
/// when the menu shows, so a send elsewhere in the chat doesn't update every
/// bubble that could be edited.
struct PromptEdit {
    let isEnabled: @MainActor () -> Bool
    let perform: @MainActor () -> Void
}

private struct PromptContextMenu: View {
    let text: String
    let edit: PromptEdit?

    var body: some View {
        if let edit {
            Button("Edit", systemImage: "pencil", action: edit.perform)
                .disabled(!edit.isEnabled())
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
