#if os(macOS)
import AppKit
#endif
import SwiftUI

/// Attaches images to the prompt, beside the composer, and brings back
/// drafts from the project's scratchpad, the only way to its sheet. The pickers it opens are presented
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
            if let item, item.task.workspaceID != nil {
                Divider()
                if item.scratchpad.isEmpty {
                    Button("Scratchpad", systemImage: "note.text") {
                        composer.isShowingScratchpad = true
                    }
                } else {
                    scratchpadMenu(item)
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

    /// The newest drafts to restore, then Show All for the sheet.
    private func scratchpadMenu(_ item: HostTask) -> some View {
        Menu {
            ForEach(item.scratchpad.prefix(Self.menuDraftLimit)) { draft in
                Button {
                    composer.restore(draft, from: item)
                } label: {
                    let lines = menuLines(for: draft)
                    Label(lines.title, systemImage: draft.hasText ? "text.alignleft" : "photo")
                    if let subtitle = lines.subtitle { Text(subtitle) }
                }
            }
            Divider()
            Button("Show All", systemImage: "list.bullet") {
                composer.isShowingScratchpad = true
            }
        } label: {
            Label("Scratchpad", systemImage: "note.text")
        }
    }

    /// The newest drafts the menu lists; Show All opens the rest in the sheet.
    private static var menuDraftLimit: Int { 5 }

    /// A draft's menu item: its text, then its images. Mac menu items are
    /// one line, ignoring line breaks in titles, so a long draft is wrapped
    /// to a narrow width with its second line as the subtitle, ending in "…"
    /// when more follows.
    private func menuLines(for draft: ScratchpadDraft) -> (title: String, subtitle: String?) {
        #if os(macOS)
        guard draft.hasText else { return (draft.title, draft.imageSummary) }
        let lines = Self.wrapForMenu(draft.title, maxWidth: 240, maxLines: 2)
        return (lines.first ?? draft.title, lines.count > 1 ? lines[1] : draft.imageSummary)
        #else
        (draft.title, draft.imageSummary)
        #endif
    }

    #if os(macOS)
    private static func wrapForMenu(_ text: String, maxWidth: CGFloat, maxLines: Int) -> [String] {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return [] }
        // Two lines at 240pt hold far fewer than 500 characters; bounding
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
        return lines
    }
    #endif
}
