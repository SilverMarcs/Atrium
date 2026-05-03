import AppKit
import SwiftUI

/// AppKit-backed scrolling text view for command output. SwiftUI's `Text`
/// chokes on large strings (256 KB+ freezes layout); NSTextView handles it
/// natively. We do an incremental append when possible to avoid rebuilding
/// the entire text storage on every output chunk.
struct CommandTextView: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    var onContentHeight: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 0)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        textView.postsFrameChangedNotifications = true
        let coord = context.coordinator
        coord.textView = textView
        coord.onContentHeight = onContentHeight
        coord.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak coord] _ in
            coord?.measureAndReport()
        }

        coord.sync(text: text, fontSize: fontSize)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onContentHeight = onContentHeight
        context.coordinator.sync(text: text, fontSize: fontSize)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if let token = coordinator.frameObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var textView: NSTextView?
        var onContentHeight: ((CGFloat) -> Void)?
        var frameObserver: NSObjectProtocol?
        private var lastApplied: String = ""
        private var lastFontSize: CGFloat = 0
        private var lastReportedHeight: CGFloat = -1

        func sync(text: String, fontSize: CGFloat) {
            guard let tv = textView, let storage = tv.textStorage else { return }

            if fontSize != lastFontSize {
                let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                tv.font = font
                let range = NSRange(location: 0, length: storage.length)
                if range.length > 0 {
                    storage.setAttributes(
                        [.font: font, .foregroundColor: NSColor.textColor],
                        range: range
                    )
                    Self.colorDollars(in: storage, range: range)
                }
                lastFontSize = fontSize
            }

            if text != lastApplied {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: tv.font ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                    .foregroundColor: NSColor.textColor
                ]

                if text.hasPrefix(lastApplied) {
                    let oldLen = storage.length
                    let delta = text.dropFirst(lastApplied.count)
                    if !delta.isEmpty {
                        storage.append(NSAttributedString(string: String(delta), attributes: attrs))
                        let start = max(0, oldLen - 1)
                        let scanRange = NSRange(location: start, length: storage.length - start)
                        Self.colorDollars(in: storage, range: scanRange)
                    }
                } else {
                    storage.setAttributedString(NSAttributedString(string: text, attributes: attrs))
                    Self.colorDollars(in: storage, range: NSRange(location: 0, length: storage.length))
                }
                lastApplied = text
                tv.scrollToEndOfDocument(nil)
            }

            measureAndReport()
        }

        /// Measures the laid-out content height and reports it back to
        /// SwiftUI so the parent can size this view to its content (when
        /// short) or cap it at the available space (when long). Width must
        /// be known — measurements at zero width produce nonsense from
        /// word wrap.
        func measureAndReport() {
            guard let tv = textView,
                  let lm = tv.layoutManager,
                  let tc = tv.textContainer,
                  tv.frame.width > 0,
                  let cb = onContentHeight else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            let h = ceil(used.height) + tv.textContainerInset.height * 2
            if abs(h - lastReportedHeight) > 0.5 {
                lastReportedHeight = h
                DispatchQueue.main.async { cb(h) }
            }
        }

        /// Paints the leading `$` of any line that starts with `$ ` green so
        /// user-entered commands stand out from program output.
        private static func colorDollars(in storage: NSTextStorage, range: NSRange) {
            let ns = storage.string as NSString
            let total = ns.length
            guard range.length > 0, range.location < total else { return }
            let end = min(NSMaxRange(range), total)
            var i = range.location
            while i < end {
                let isLineStart = (i == 0) || (ns.character(at: i - 1) == 0x0A)
                if isLineStart,
                   i + 1 < total,
                   ns.character(at: i) == 0x24, // $
                   ns.character(at: i + 1) == 0x20 // space
                {
                    storage.addAttribute(
                        .foregroundColor,
                        value: NSColor.systemGreen,
                        range: NSRange(location: i, length: 1)
                    )
                }
                i += 1
            }
        }
    }
}
