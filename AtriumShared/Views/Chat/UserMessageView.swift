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
    var edit: PromptAction?
    var fork: PromptAction?
    #if os(macOS)
    /// The timeline row of a prompt sent from here, whose bubble can fly in.
    var flightRowID: String?
    #else
    /// Finds this bubble's flight, if it was just sent. A bubble that can't
    /// have one (nil) skips the effect and never observes flights.
    var sendFlight: ((PromptSendAnimator) -> PromptSendFlight?)?
    #endif
    @State private var viewedImages: ViewedImages?
    /// Names this prompt's images for the viewer, which zooms out of their thumbnails.
    @State private var imagesID = UUID()
    @Namespace private var namespace

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack {
                    let urls = PromptImageLoan.urls(id: imagesID, count: images.count)
                    ForEach(images.enumerated(), id: \.offset) { index, data in
                        Button {
                            viewedImages = ViewedImages(prompt: images, id: imagesID, startIndex: index)
                        } label: {
                            PromptImageThumbnail(data: data)
                        }
                        .buttonStyle(.plain)
                        #if os(iOS)
                        .matchedTransitionSource(id: urls[index], in: namespace) {
                            $0.clipShape(.rect(cornerRadius: PromptImageThumbnail.cornerRadius))
                        }
                        #endif
                    }
                }
                .contextMenu { PromptContextMenu(text: text, edit: edit, fork: fork) }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !text.isEmpty {
                PromptBubble(text: text, isFromAgent: isFromAgent)
                // Menu sits on the bubble itself so iOS lifts just the bubble, not the full-width row.
                #if os(iOS)
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 20))
                #endif
                .contextMenu { PromptContextMenu(text: text, edit: edit, fork: fork) }
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
        .imageViewer($viewedImages, namespace: namespace)
    }
}

/// Editing a prompt, or forking the chat before it, from its bubble's menu.
/// Whether it's allowed is read when the menu shows, so a send elsewhere in
/// the chat doesn't update every bubble that offers it.
struct PromptAction {
    let isEnabled: @MainActor () -> Bool
    let perform: @MainActor () -> Void
}

private struct PromptContextMenu: View {
    let text: String
    let edit: PromptAction?
    let fork: PromptAction?

    var body: some View {
        if let edit {
            Button("Edit", systemImage: "pencil", action: edit.perform)
                .disabled(!edit.isEnabled())
        }
        if let fork {
            Button("Fork from Here", systemImage: "arrow.triangle.branch", action: fork.perform)
                .disabled(!fork.isEnabled())
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
