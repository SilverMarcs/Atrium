import AppKit
import AtriumProtocol
import SwiftUI

/// A command's output in a selectable, searchable text view. It keeps up with
/// long output by changing only the lines that changed, follows new output
/// while scrolled to the end, and makes file paths and web links clickable.
struct CommandOutputTextView: NSViewRepresentable {
    let output: WireCommandOutput?
    let fontSize: Double
    let openLink: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.layoutManager?.allowsNonContiguousLayout = true
        // Links show only as the pointer passes over them, so paths in busy output stay readable.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.openLink = openLink
        context.coordinator.show(output, font: .monospacedSystemFont(ofSize: fontSize, weight: .regular))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        var openLink: (String) -> Void = { _ in }
        /// The output shown, and the length of each line shown, without the line breaks between them.
        private var shown: (id: UUID, firstLine: Int)?
        private var lengths: [Int] = []
        private var font: NSFont?

        func show(_ output: WireCommandOutput?, font: NSFont) {
            guard let textView, let storage = textView.textStorage else { return }
            let isAtEnd = textView.visibleRect.maxY >= textView.bounds.maxY - 4
            storage.beginEditing()
            if font != self.font {
                self.font = font
                storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
            }
            if let output, let shown, shown.id == output.id, output.firstLine >= shown.firstLine,
               output.firstLine - shown.firstLine < lengths.count {
                // Lines the host no longer keeps go, each with the break after it.
                let dropped = output.firstLine - shown.firstLine
                storage.deleteCharacters(in: NSRange(location: 0, length: lengths.prefix(dropped).reduce(0, +) + dropped))
                lengths.removeFirst(dropped)
                // Only the last line shown can have changed since; the rest stay.
                let kept = min(lengths.count - 1, output.lines.count)
                lengths.removeLast(lengths.count - kept)
                append(output.lines[kept...], to: storage)
            } else {
                lengths = []
                append(output?.lines[...] ?? [], to: storage)
            }
            shown = output.map { ($0.id, $0.firstLine) }
            storage.endEditing()
            if isAtEnd { textView.scrollToEndOfDocument(nil) }
        }

        /// Replaces everything after the lines in `lengths` with `lines`.
        private func append(_ lines: ArraySlice<String>, to storage: NSTextStorage) {
            let location = lengths.reduce(0, +) + max(lengths.count - 1, 0)
            let text = (lengths.isEmpty || lines.isEmpty ? "" : "\n") + lines.joined(separator: "\n")
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ])
            for match in Self.links.matches(in: text, range: NSRange(location: 0, length: attributed.length)) {
                let link = (text as NSString).substring(with: match.range).trimmingCharacters(in: Self.trailingPunctuation)
                attributed.addAttribute(.link, value: link, range: NSRange(location: match.range.location, length: (link as NSString).length))
            }
            storage.replaceCharacters(in: NSRange(location: location, length: storage.length - location), with: attributed)
            lengths += lines.map(\.utf16.count)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let link = link as? String else { return false }
            openLink(link)
            return true
        }

        /// Web links, paths with a folder (as `/a/b`, `~/a`, `./a` or `a/b.c`), and file
        /// names with a line number, each with an optional `:line:column`.
        private static let links = try! NSRegularExpression(pattern: #"""
            https?://[^\s'"<>]+|(?:(?:~|\.{1,2})?/[\w.@+-]+(?:/[\w.@+-]+)*|[\w.@+-]+(?:/[\w.@+-]+)+\.\w+|[\w@+-]+(?:\.[\w@+-]+)*\.\w+(?=:\d))(?::\d+){0,2}
            """#)
        private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:")
    }
}
