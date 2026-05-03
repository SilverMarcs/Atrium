import AppKit
import SwiftUI

/// AppKit-backed scrolling text view for command output. Uses NSTextView's
/// non-contiguous layout for low-overhead append performance and tracks
/// "stuck to bottom" state so streaming output keeps following until the user
/// scrolls up.
struct CommandTextView: NSViewRepresentable {
    let command: Command
    let fontSize: CGFloat

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
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.layoutManager?.allowsNonContiguousLayout = true
        // Wrap to the scroll view width.
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false

        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView
        context.coordinator.bind(to: command)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if context.coordinator.command !== command {
            context.coordinator.bind(to: command)
        }
        if let tv = scrollView.documentView as? NSTextView {
            let newFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            if tv.font != newFont {
                tv.font = newFont
                let range = NSRange(location: 0, length: tv.textStorage?.length ?? 0)
                tv.textStorage?.setAttributes(
                    [.font: newFont, .foregroundColor: NSColor.textColor],
                    range: range
                )
            }
        }
        // Pull any pending output the model has accumulated between updates.
        context.coordinator.flushPending()
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.unbind()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        private(set) var command: Command?
        private var observationTask: Task<Void, Never>?

        func bind(to command: Command) {
            unbind()
            self.command = command
            // Reset the view to the model's current full text.
            if let tv = textView {
                tv.textStorage?.setAttributedString(NSAttributedString(string: ""))
                let initial = command.output.fullText
                if !initial.isEmpty {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: tv.font ?? NSFont.monospacedSystemFont(ofSize: TerminalFontSize.current, weight: .regular),
                        .foregroundColor: NSColor.textColor
                    ]
                    tv.textStorage?.append(NSAttributedString(string: initial, attributes: attrs))
                }
                _ = command.output.drainPending()  // discard delta we already covered
                tv.scrollToEndOfDocument(nil)
            }
            startObserving()
        }

        func unbind() {
            observationTask?.cancel()
            observationTask = nil
        }

        private func startObserving() {
            guard let command else { return }
            // Loop using Observation: re-arm tracking after each change so we
            // pick up subsequent edits to `version`.
            observationTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, let command = self.command else { return }
                    let stream = AsyncStream<Void> { continuation in
                        withObservationTracking {
                            _ = command.output.version
                        } onChange: {
                            continuation.yield()
                            continuation.finish()
                        }
                    }
                    for await _ in stream {
                        await MainActor.run { self.flushPending() }
                    }
                }
            }
        }

        func flushPending() {
            guard let command, let tv = textView else { return }
            let delta = command.output.drainPending()
            guard !delta.isEmpty else { return }
            applyDelta(delta, to: tv)
        }

        private func applyDelta(_ delta: String, to tv: NSTextView) {
            let storage = tv.textStorage
            let scroller = scrollView?.verticalScroller
            // "Stuck to bottom" if the user hasn't scrolled away.
            let stickToBottom: Bool = {
                if let v = scroller?.floatValue { return v > 0.98 }
                return true
            }()

            // Parse our two private control sequences out of the delta and
            // apply them as text-storage edits.
            var i = delta.startIndex
            while i < delta.endIndex {
                if delta[i] == "\u{1B}",
                   let bracket = delta.index(i, offsetBy: 1, limitedBy: delta.endIndex),
                   bracket < delta.endIndex,
                   delta[bracket] == "[" {
                    if delta[i...].hasPrefix("\u{1B}[CLEAR]") {
                        storage?.setAttributedString(NSAttributedString(string: ""))
                        i = delta.index(i, offsetBy: "\u{1B}[CLEAR]".count)
                        continue
                    }
                    if delta[i...].hasPrefix("\u{1B}[REWIND:") {
                        let prefix = "\u{1B}[REWIND:"
                        let after = delta.index(i, offsetBy: prefix.count)
                        if let close = delta[after...].firstIndex(of: "]"),
                           let n = Int(delta[after..<close]),
                           let storage {
                            let len = storage.length
                            let drop = min(n, len)
                            storage.deleteCharacters(in: NSRange(location: len - drop, length: drop))
                            i = delta.index(after: close)
                            continue
                        }
                    }
                }
                // Find the next escape (or end) and append the run as plain text.
                let next = delta[i...].firstIndex(of: "\u{1B}") ?? delta.endIndex
                let run = String(delta[i..<next])
                if !run.isEmpty {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: tv.font ?? NSFont.monospacedSystemFont(ofSize: TerminalFontSize.current, weight: .regular),
                        .foregroundColor: NSColor.textColor
                    ]
                    storage?.append(NSAttributedString(string: run, attributes: attrs))
                }
                i = next
            }

            if stickToBottom { tv.scrollToEndOfDocument(nil) }
        }
    }
}
