#if os(macOS)
import AppKit
#endif
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
                            Label(menuTitle(for: draft), systemImage: draft.hasText ? "text.alignleft" : "photo")
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

    /// Mac menus don't wrap on their own, so long drafts are wrapped to a
    /// fixed width and at most three lines, ending in "…" when more follows.
    private func menuTitle(for draft: ScratchpadDraft) -> String {
        #if os(macOS)
        guard draft.hasText else { return draft.title }
        return Self.wrapForMenu(draft.title, maxWidth: 260, maxLines: 3)
        #else
        draft.title
        #endif
    }

    #if os(macOS)
    private static func wrapForMenu(_ text: String, maxWidth: CGFloat, maxLines: Int) -> String {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return "" }
        // Three lines at 260pt hold far fewer than 500 characters; bounding
        // avoids laying out giant pasted drafts on the main actor.
        let sample = String(normalized.prefix(500))
        let storage = NSTextStorage(string: sample, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        let container = NSTextContainer(size: NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maxLines
        container.lineBreakMode = .byTruncatingTail
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)

        let source = sample as NSString
        var lines: [String] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphRange, _ in
            let truncated = layout.truncatedGlyphRange(inLineFragmentForGlyphAt: glyphRange.location)
            let visible = truncated.location == NSNotFound
                ? glyphRange
                : NSRange(location: glyphRange.location, length: truncated.location - glyphRange.location)
            let chars = layout.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
            let line = source.substring(with: chars).trimmingCharacters(in: .whitespaces)
            lines.append(truncated.location == NSNotFound ? line : line + "…")
        }
        return lines.joined(separator: "\n")
    }
    #endif
}
