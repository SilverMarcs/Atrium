import AppKit
import UniformTypeIdentifiers

/// Pastes images and files into the composer as attachments, through the
/// same decoder as on iPhone and iPad. Text read from a pasted file goes in
/// at the editor's selection, with undo, as pasted text does.
@MainActor
final class ComposerPasteDelegate {
    private weak var composer: TaskComposer?

    init(composer: TaskComposer) {
        self.composer = composer
    }

    /// Takes the pasteboard's images and files, returning whether there
    /// were any. Anything else is left for the editor to paste as text.
    func paste(from pasteboard: NSPasteboard, into editor: NSTextView) -> Bool {
        guard let composer else { return false }
        let items = (pasteboard.pasteboardItems ?? []).filter { item in
            if let url = Self.fileURL(from: item) {
                return ComposerPasteContent.supports(url)
            }
            return Self.imageType(of: item) != nil
        }
        guard !items.isEmpty else { return false }
        Task { [weak editor] in
            for item in items {
                do {
                    let content: ComposerPasteContent
                    if let url = Self.fileURL(from: item) {
                        do {
                            content = try await ComposerPasteContent.load(contentsOf: url)
                        } catch {
                            // Spotlight's clipboard history pastes its cached copy of the
                            // file, which only Full Disk Access can read, alongside the
                            // image itself.
                            guard let data = Self.imageData(of: item) else { throw error }
                            try composer.checkImageSlot()
                            content = try await ComposerPasteContent.load(imageData: data)
                        }
                    } else if let data = Self.imageData(of: item) {
                        try composer.checkImageSlot()
                        content = try await ComposerPasteContent.load(imageData: data)
                    } else {
                        continue
                    }
                    switch content {
                    case .text(let text):
                        // The editor may have moved on to another chat's draft meanwhile.
                        if let editor, editor.window?.firstResponder === editor, editor.string == composer.draft {
                            editor.insertText(text, replacementRange: editor.selectedRange())
                        } else {
                            composer.draft += text
                        }
                    case .image(let image):
                        try composer.attachPastedImage(image)
                    }
                } catch {
                    composer.attachmentError = error.localizedDescription
                }
            }
        }
        return true
    }

    private static func imageType(of item: NSPasteboardItem) -> NSPasteboard.PasteboardType? {
        item.availableType(from: ComposerPasteContent.imageTypes.map { NSPasteboard.PasteboardType($0.identifier) })
    }

    private static func imageData(of item: NSPasteboardItem) -> Data? {
        imageType(of: item).flatMap(item.data(forType:))
    }

    private static func fileURL(from item: NSPasteboardItem) -> URL? {
        guard let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL else { return nil }
        return url
    }
}
