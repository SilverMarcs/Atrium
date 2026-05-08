import AppKit
import SwiftUI

/// NSView subclass that fires a callback whenever AppKit changes its frame
/// size. SwiftUI's `updateNSView` is not reliably re-invoked when the
/// container resizes (e.g. when the bottom sheet finishes its open animation
/// or when the source-control inspector swaps in a new editor instance), so
/// the editor used to be stuck rendering whatever broken state was cached at
/// the bad initial size. This callback gives us a deterministic hook to
/// re-run the layout pass once the geometry is actually usable.
final class LayoutAwareContainer: NSView {
    var onResize: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onResize?() }
    }
}

struct CodeTextEditor: NSViewRepresentable {
    private enum Mode {
        case editable(gutterDiff: GutterDiffResult, highlightRequest: HighlightRequest?)
        case diff(
            presentation: GitDiffPresentation,
            hunks: [DiffHunk],
            reference: GitDiffReference,
            onReload: () async -> Void
        )
    }

    private let text: Binding<String>?
    private let documentID: AnyHashable?
    let fileExtension: String
    private let mode: Mode
    private let repositoryRootURL: URL?
    private let onReloadFromDisk: (() async -> Void)?
    private let onSave: (() -> Void)?
    @Environment(\.editorFontSize) private var fontSize
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("editorWrapLines") private var wrapLines: Bool = true

    private var isDark: Bool { colorScheme == .dark }

    init(
        text: Binding<String>,
        documentID: AnyHashable,
        fileExtension: String,
        gutterDiff: GutterDiffResult,
        highlightRequest: HighlightRequest?,
        repositoryRootURL: URL? = nil,
        onReloadFromDisk: (() async -> Void)? = nil,
        onSave: (() -> Void)? = nil
    ) {
        self.text = text
        self.documentID = documentID
        self.fileExtension = fileExtension
        self.mode = .editable(gutterDiff: gutterDiff, highlightRequest: highlightRequest)
        self.repositoryRootURL = repositoryRootURL
        self.onReloadFromDisk = onReloadFromDisk
        self.onSave = onSave
    }

    init(
        presentation: GitDiffPresentation,
        fileExtension: String,
        hunks: [DiffHunk],
        reference: GitDiffReference,
        onReload: @escaping () async -> Void
    ) {
        text = nil
        documentID = nil
        self.fileExtension = fileExtension
        repositoryRootURL = nil
        onReloadFromDisk = nil
        onSave = nil
        mode = .diff(
            presentation: presentation,
            hunks: hunks,
            reference: reference,
            onReload: onReload
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        let container = LayoutAwareContainer()
        container.autoresizesSubviews = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]

        let textContainer = NSTextContainer(
            containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let contentSize = scrollView.contentSize
        let textView = EditorTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
        configureSharedTextView(textView, contentSize: contentSize)

        let minimap = EditorMinimap()
        minimap.autoresizingMask = [.minXMargin, .height]
        minimap.onScrollToFraction = { [weak scrollView] fraction in
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let totalHeight = documentView.frame.height
            let visibleHeight = scrollView.contentView.bounds.height
            let targetY = max(0, min(fraction * totalHeight - visibleHeight / 2, totalHeight - visibleHeight))
            scrollView.contentView.setBoundsOrigin(
                NSPoint(x: scrollView.contentView.bounds.origin.x, y: targetY)
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        scrollView.documentView = textView
        container.addSubview(scrollView)
        container.addSubview(minimap)

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.minimap = minimap

        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.installScrollObserver(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Don't call configureMode here. Loading the file's text in makeNSView
        // means setAttributedString runs against a textContainer that hasn't
        // been sized yet (scrollView.frame is still .zero until updateNSView
        // runs), so the initial layout passes use an unbounded container width.
        // Once updateNSView later runs applyWrapping, invalidateLayout marks
        // the glyphs dirty but the wide cached layout sticks until something
        // forces a fresh setAttributedString — which is why typing any
        // character (the rehighlight path) made the gutter cut-off go away.
        // Defer configureMode to updateNSView so text is laid out exactly once,
        // in the correctly sized container.

        container.onResize = { [weak coordinator = context.coordinator, weak container] in
            guard let coordinator, let container else { return }
            coordinator.parent.runLayoutPass(container: container, coordinator: coordinator)
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.parent = self
        runLayoutPass(container: container, coordinator: context.coordinator, fromSwiftUI: true)
    }

    /// Shared layout pass invoked both from SwiftUI's `updateNSView` and from
    /// the container's frame-change callback. When `fromSwiftUI` is true and
    /// `didConfigureMode` is already set, also drive `updateMode` for any
    /// SwiftUI state changes (text binding, gutter diff, dark mode, etc).
    fileprivate func runLayoutPass(container: NSView, coordinator: Coordinator, fromSwiftUI: Bool = false) {
        guard let textView = coordinator.textView else { return }
        let bounds = container.bounds
        let minimapWidth = EditorTextViewConstants.minimapWidth

        let scrollViewFrame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width - minimapWidth,
            height: bounds.height
        )
        coordinator.scrollView?.frame = scrollViewFrame
        coordinator.minimap?.frame = NSRect(
            x: bounds.width - minimapWidth,
            y: 0,
            width: minimapWidth,
            height: bounds.height
        )

        updateSharedTextView(textView)

        // We need bounds.width > 0 (otherwise the NSRect normalization
        // shenanigans below kick in) AND room to fit at least the gutter
        // inset on both sides — without this, `applyWrapping` derives a
        // negative containerWidth (e.g. 16 - 96 = -80) and configureMode
        // caches a broken layout that doesn't recover when the real width
        // arrives. Check container.bounds.width, NOT scrollViewFrame.width:
        // NSRect(width: -16) normalizes to (x: -16, width: 16), so a
        // `scrollViewFrame.width > 0` guard passes even when bounds.width is
        // 0.
        guard let minimap = coordinator.minimap else { return }
        let minimumWidth = EditorTextViewConstants.minimapWidth + 2 * textView.textContainerInset.width
        let geometryUsable = bounds.width >= minimumWidth

        if geometryUsable {
            applyWrapping(textView: textView, contentWidth: scrollViewFrame.width, coordinator: coordinator)
        }

        if !coordinator.didConfigureMode, geometryUsable {
            coordinator.didConfigureMode = true
            configureMode(textView: textView, minimap: minimap, coordinator: coordinator)
        } else if coordinator.didConfigureMode, fromSwiftUI {
            updateMode(textView: textView, coordinator: coordinator)
        }
        textView.needsDisplay = true
    }

    /// Toggles soft-wrap on the underlying NSTextView. When wrapping is on the
    /// text container width tracks the scroll view's content width; otherwise
    /// the text view is allowed to grow horizontally. Order of operations
    /// mirrors Apple's TextEdit sample — setting the container size before
    /// flipping `widthTracksTextView`, then explicitly resizing the text view
    /// frame and forcing the layout manager to re-flow when state changes.
    private func applyWrapping(textView: EditorTextView, contentWidth: CGFloat, coordinator: Coordinator) {
        guard let textContainer = textView.textContainer else { return }
        let layoutManager = textContainer.layoutManager
        let scrollViewHeight = coordinator.scrollView?.contentSize.height ?? 0

        let stateChanged = coordinator.lastWrapLines != wrapLines
        let widthChanged = coordinator.lastWrapContentWidth != contentWidth
        coordinator.lastWrapLines = wrapLines
        coordinator.lastWrapContentWidth = contentWidth

        if wrapLines {
            let inset = textView.textContainerInset.width * 2
            let containerWidth = max(0, contentWidth - inset)
            textView.minSize = NSSize(width: 0, height: scrollViewHeight)
            textView.maxSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
            textView.isHorizontallyResizable = false
            textContainer.containerSize = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
            textContainer.widthTracksTextView = true
            let newHeight = max(textView.frame.height, scrollViewHeight)
            textView.setFrameSize(NSSize(width: contentWidth, height: newHeight))
        } else {
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.minSize = NSSize(width: 0, height: scrollViewHeight)
            textView.isHorizontallyResizable = true
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            if textView.frame.height < scrollViewHeight {
                textView.setFrameSize(NSSize(width: textView.frame.width, height: scrollViewHeight))
            }
        }

        if (stateChanged || widthChanged), let layoutManager, let textStorage = textView.textStorage {
            layoutManager.textContainerChangedGeometry(textContainer)
            let fullRange = NSRange(location: 0, length: textStorage.length)
            layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)

            // invalidateLayout marks layout dirty but AppKit keeps the
            // cached glyph positions from the previous container width, so
            // the visible text stays clipped/offset until something forces a
            // fresh setAttributedString. Re-applying the existing storage
            // forces a real relayout while preserving selection.
            if coordinator.didConfigureMode, textStorage.length > 0 {
                let preservedRanges = textView.selectedRanges
                let snapshot = NSAttributedString(attributedString: textStorage)
                textStorage.setAttributedString(snapshot)
                textView.setSelectedRanges(preservedRanges, affinity: .downstream, stillSelecting: false)
            }

            layoutManager.ensureLayout(for: textContainer)
            textView.needsLayout = true
            textView.needsDisplay = true
        }
    }

    private func configureSharedTextView(_ textView: EditorTextView, contentSize: NSSize) {
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        // Preserve syntax highlighting under selection: only paint a background,
        // don't let AppKit override the foreground colors Highlightr applied.
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor
        ]
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.editorFontSize = fontSize
        textView.lineNumberFontSize = fontSize - 1
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = []

        // Set the gutter inset up front so the very first applyWrapping pass
        // (in updateNSView, before configureMode runs) computes the correct
        // container width = contentWidth - 2 * gutterInset. Otherwise the
        // first paint wraps at the full content width and lines extend past
        // the visible area until something forces a fresh setAttributedString
        // (e.g. the rehighlight after typing a character) — which is the
        // first-time-bottom-sheet-expansion gutter cut-off.
        let gutterInset: CGFloat
        switch mode {
        case .editable: gutterInset = EditorTextViewConstants.gutterWidth
        case .diff: gutterInset = EditorTextViewConstants.diffGutterWidth
        }
        textView.textContainerInset = NSSize(width: gutterInset, height: 4)
    }

    private func updateSharedTextView(_ textView: EditorTextView) {
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.editorFontSize = fontSize
        textView.lineNumberFontSize = fontSize - 1
        textView.fileExtension = fileExtension
    }

    private func configureMode(textView: EditorTextView, minimap: EditorMinimap, coordinator: Coordinator) {
        switch mode {
        case .editable(let gutterDiff, let highlightRequest):
            textView.isEditable = true
            textView.allowsUndo = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.textContainerInset = NSSize(width: EditorTextViewConstants.gutterWidth, height: 4)
            textView.delegate = coordinator
            textView.gutterDiff = gutterDiff
            textView.diffLineKinds = [:]
            textView.diffLineNumbers = [:]
            textView.diffGutterClickHandler = nil
            textView.repositoryRootURL = repositoryRootURL
            textView.gutterDiffReloadHandler = onReloadFromDisk
            textView.saveHandler = onSave

            if let text {
                coordinator.applyHighlight(
                    source: text.wrappedValue,
                    fileExtension: fileExtension,
                    fontSize: fontSize,
                    isDark: isDark,
                    preserveSelection: false,
                    postProcess: { textView, _ in
                        textView.recomputeFolding()
                    }
                )
            }

            coordinator.updateMinimapMarkers(gutterDiff: gutterDiff, text: textView.string)

            if let highlightRequest {
                coordinator.lastAppliedHighlight = highlightRequest
                // applyHighlight above kicks off an async syntax pass that
                // ends with setAttributedString — running it after the find
                // indicator would dismiss the indicator overlay. Defer.
                coordinator.pendingFindHighlight = highlightRequest
            }

            // Seed the bookkeeping that updateMode compares against, so the
            // first updateMode after any text edit doesn't incorrectly see
            // documentChanged/colorSchemeChanged as true and reset the
            // cursor to position 0 + scroll to top.
            coordinator.lastDocumentID = documentID
            coordinator.lastIsDark = isDark

            finalizeInitialLayout(textView: textView, coordinator: coordinator)

        case .diff(let presentation, let hunks, let reference, let onReload):
            textView.isEditable = false
            textView.allowsUndo = false
            textView.textContainerInset = NSSize(width: EditorTextViewConstants.diffGutterWidth, height: 4)
            textView.delegate = nil
            textView.gutterDiff = .empty
            textView.diffLineKinds = presentation.lineKinds
            textView.diffLineNumbers = presentation.lineNumbers

            coordinator.presentation = presentation
            coordinator.hunks = hunks
            coordinator.reference = reference
            coordinator.onReload = onReload
            coordinator.buildHunkLookup()

            textView.diffGutterClickHandler = { [weak coordinator] renderLine, point in
                coordinator?.handleGutterClick(renderLine: renderLine, at: point)
            }

            let lineKinds = presentation.lineKinds
            coordinator.applyHighlight(
                source: presentation.string,
                fileExtension: fileExtension,
                fontSize: fontSize,
                isDark: isDark,
                preserveSelection: false,
                postProcess: { _, storage in
                    Self.applyInlineHighlights(to: storage, lineKinds: lineKinds)
                }
            )
            coordinator.lastIsDark = isDark

            coordinator.updateMinimapMarkers(lineKinds: presentation.lineKinds, text: presentation.string)

            Task { @MainActor in
                if let firstLine = presentation.firstChangedLine {
                    textView.scrollToLine(max(firstLine - 3, 1))
                }
            }

            coordinator.lastDocumentID = documentID

            finalizeInitialLayout(textView: textView, coordinator: coordinator)
        }

        minimap.totalLines = max(textView.string.components(separatedBy: "\n").count, 1)
    }

    /// Forces a fresh layout pass on the text view's contents and resets the
    /// scroll origin to the top-left. Call once after the very first
    /// setAttributedString in `configureMode`. Without this, the initial paint
    /// can show stale glyph positions cached from when the text container had
    /// its placeholder geometry, plus a non-zero clip view origin from
    /// AppKit's auto-scroll-to-selection during the first text load — which
    /// is what the post-edit re-highlight was inadvertently fixing.
    private func finalizeInitialLayout(textView: EditorTextView, coordinator: Coordinator) {
        if let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer,
           let textStorage = textView.textStorage,
           textStorage.length > 0 {
            let fullRange = NSRange(location: 0, length: textStorage.length)
            layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
            layoutManager.ensureLayout(for: textContainer)
        }

        if let scrollView = coordinator.scrollView {
            scrollView.contentView.setBoundsOrigin(.zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            coordinator.minimap?.updateViewport(from: scrollView)
        }

        textView.needsLayout = true
        textView.needsDisplay = true
    }

    private func updateMode(textView: EditorTextView, coordinator: Coordinator) {
        let colorSchemeChanged = coordinator.lastIsDark != isDark
        let documentChanged = coordinator.lastDocumentID != documentID

        switch mode {
        case .editable(let gutterDiff, let highlightRequest):
            textView.isEditable = true
            textView.textContainerInset = NSSize(width: EditorTextViewConstants.gutterWidth, height: 4)
            textView.gutterDiff = gutterDiff
            textView.diffLineKinds = [:]
            textView.diffLineNumbers = [:]
            textView.diffGutterClickHandler = nil
            textView.repositoryRootURL = repositoryRootURL
            textView.gutterDiffReloadHandler = onReloadFromDisk
            textView.saveHandler = onSave

            coordinator.updateMinimapMarkers(gutterDiff: gutterDiff, text: textView.string)

            let willApplyHighlight = text != nil && !coordinator.isEditing &&
                (textView.string != text!.wrappedValue || colorSchemeChanged || documentChanged)

            if let text, willApplyHighlight {
                coordinator.applyHighlight(
                    source: text.wrappedValue,
                    fileExtension: fileExtension,
                    fontSize: fontSize,
                    isDark: isDark,
                    preserveSelection: true,
                    preserveScroll: !documentChanged,
                    postProcess: { textView, _ in
                        textView.recomputeFolding()
                        textView.applyFoldAttributes()
                    }
                )
            }

            if let highlightRequest, highlightRequest != coordinator.lastAppliedHighlight {
                coordinator.lastAppliedHighlight = highlightRequest
                if willApplyHighlight {
                    // Defer: applyHighlight's async pass would dismiss the
                    // find indicator if scroll-and-highlight ran first.
                    coordinator.pendingFindHighlight = highlightRequest
                } else {
                    Task { @MainActor in
                        textView.scrollToLineAndHighlight(
                            lineNumber: highlightRequest.lineNumber,
                            columnRange: highlightRequest.columnRange
                        )
                    }
                }
            } else if documentChanged {
                coordinator.lastAppliedHighlight = nil
                Task { @MainActor in
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                    if let scrollView = coordinator.scrollView {
                        scrollView.contentView.setBoundsOrigin(.zero)
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                        coordinator.minimap?.updateViewport(from: scrollView)
                    } else {
                        textView.scrollToLine(1)
                    }
                }
            }

        case .diff(let presentation, let hunks, let reference, let onReload):
            textView.isEditable = false
            textView.textContainerInset = NSSize(width: EditorTextViewConstants.diffGutterWidth, height: 4)
            textView.gutterDiff = .empty
            textView.diffLineKinds = presentation.lineKinds
            textView.diffLineNumbers = presentation.lineNumbers

            let referenceChanged = coordinator.reference != reference
            coordinator.presentation = presentation
            coordinator.hunks = hunks
            coordinator.reference = reference
            coordinator.onReload = onReload
            coordinator.buildHunkLookup()

            if textView.string != presentation.string || colorSchemeChanged {
                let lineKinds = presentation.lineKinds
                coordinator.applyHighlight(
                    source: presentation.string,
                    fileExtension: fileExtension,
                    fontSize: fontSize,
                    isDark: isDark,
                    preserveSelection: false,
                    preserveScroll: !referenceChanged,
                    postProcess: { _, storage in
                        Self.applyInlineHighlights(to: storage, lineKinds: lineKinds)
                    }
                )
            }

            coordinator.updateMinimapMarkers(lineKinds: presentation.lineKinds, text: presentation.string)
        }

        coordinator.lastDocumentID = documentID
        coordinator.lastIsDark = isDark
    }

    private static func applyInlineHighlights(to textStorage: NSTextStorage?, lineKinds: [Int: GitDiffLineKind]) {
        guard let textStorage else { return }
        let text = textStorage.string as NSString
        guard text.length > 0 else { return }

        var lineStarts: [Int] = [0]
        for i in 0..<text.length where text.character(at: i) == 0x0A {
            lineStarts.append(i + 1)
        }

        let lineCount = lineStarts.count

        func lineContent(_ lineIndex: Int) -> String {
            guard lineIndex < lineStarts.count else { return "" }
            let start = lineStarts[lineIndex]
            let end: Int
            if lineIndex + 1 < lineStarts.count {
                end = lineStarts[lineIndex + 1] - 1
            } else {
                end = text.length
            }
            guard end > start else { return "" }
            return text.substring(with: NSRange(location: start, length: end - start))
        }

        var i = 1
        while i <= lineCount {
            guard lineKinds[i] == .removed else {
                i += 1
                continue
            }

            let removedStart = i
            while i <= lineCount && lineKinds[i] == .removed {
                i += 1
            }
            let removedEnd = i

            guard i <= lineCount && lineKinds[i] == .added else { continue }
            let addedStart = i
            while i <= lineCount && lineKinds[i] == .added {
                i += 1
            }
            let addedEnd = i

            let pairCount = min(removedEnd - removedStart, addedEnd - addedStart)
            for pairIndex in 0..<pairCount {
                let removedLineIndex = removedStart + pairIndex - 1
                let addedLineIndex = addedStart + pairIndex - 1
                guard removedLineIndex < lineStarts.count, addedLineIndex < lineStarts.count else { continue }

                let oldLine = lineContent(removedLineIndex)
                let newLine = lineContent(addedLineIndex)
                let (oldRange, newRange) = inlineDiffRanges(old: oldLine, new: newLine)

                if let oldRange {
                    let range = NSRange(
                        location: lineStarts[removedLineIndex] + oldRange.lowerBound,
                        length: oldRange.upperBound - oldRange.lowerBound
                    )
                    if range.upperBound <= textStorage.length {
                        textStorage.addAttribute(
                            .backgroundColor,
                            value: NSColor.systemRed.withAlphaComponent(0.22),
                            range: range
                        )
                    }
                }

                if let newRange {
                    let range = NSRange(
                        location: lineStarts[addedLineIndex] + newRange.lowerBound,
                        length: newRange.upperBound - newRange.lowerBound
                    )
                    if range.upperBound <= textStorage.length {
                        textStorage.addAttribute(
                            .backgroundColor,
                            value: NSColor.systemGreen.withAlphaComponent(0.22),
                            range: range
                        )
                    }
                }
            }
        }
    }

    private static func inlineDiffRanges(old: String, new: String) -> (Range<Int>?, Range<Int>?) {
        let oldCharacters = Array(old.utf16)
        let newCharacters = Array(new.utf16)

        var prefixLength = 0
        let minimumLength = min(oldCharacters.count, newCharacters.count)
        while prefixLength < minimumLength && oldCharacters[prefixLength] == newCharacters[prefixLength] {
            prefixLength += 1
        }

        let maximumSuffixLength = min(
            oldCharacters.count - prefixLength,
            newCharacters.count - prefixLength
        )
        var suffixLength = 0
        while suffixLength < maximumSuffixLength {
            let oldIndex = oldCharacters.count - 1 - suffixLength
            let newIndex = newCharacters.count - 1 - suffixLength
            guard oldCharacters[oldIndex] == newCharacters[newIndex] else { break }
            suffixLength += 1
        }

        let oldDiffEnd = oldCharacters.count - suffixLength
        let newDiffEnd = newCharacters.count - suffixLength
        let oldLength = oldDiffEnd - prefixLength
        let newLength = newDiffEnd - prefixLength
        if oldLength <= 0 && newLength <= 0 {
            return (nil, nil)
        }

        let oldRange = oldLength > 0 ? prefixLength..<oldDiffEnd : nil
        let newRange = newLength > 0 ? prefixLength..<newDiffEnd : nil
        return (oldRange, newRange)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextEditor
        weak var textView: EditorTextView?
        weak var scrollView: NSScrollView?
        weak var minimap: EditorMinimap?
        var isEditing = false
        var didConfigureMode = false
        var lastAppliedHighlight: HighlightRequest?
        var pendingFindHighlight: HighlightRequest?
        var lastDocumentID: AnyHashable?
        var lastWrapLines: Bool?
        var lastWrapContentWidth: CGFloat?
        var lastIsDark: Bool?
        private var rehighlightTask: Task<Void, Never>?
        private var highlightTask: Task<Void, Never>?
        private var highlightGeneration: Int = 0

        var presentation: GitDiffPresentation?
        var hunks: [DiffHunk] = []
        var reference: GitDiffReference?
        var onReload: (() async -> Void)?
        private var newLineToHunkIndex: [Int: Int] = [:]
        private var oldLineToHunkIndex: [Int: Int] = [:]
        private var scrollObserver: NSObjectProtocol?

        init(parent: CodeTextEditor) {
            self.parent = parent
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
            rehighlightTask?.cancel()
            highlightTask?.cancel()
        }

        /// Paints `source` as plain monospaced text immediately, then kicks
        /// off an off-main syntax-highlighting pass. When the pass finishes,
        /// the result is applied to the text view only if no newer highlight
        /// has been requested in the meantime (generation match).
        func applyHighlight(
            source: String,
            fileExtension: String,
            fontSize: CGFloat,
            isDark: Bool,
            preserveSelection: Bool,
            preserveScroll: Bool = false,
            postProcess: (@MainActor (EditorTextView, NSTextStorage) -> Void)? = nil
        ) {
            guard let textView, let storage = textView.textStorage else { return }

            let ranges = preserveSelection ? textView.selectedRanges : nil
            let scrollOrigin = preserveScroll ? scrollView?.contentView.bounds.origin : nil
            storage.setAttributedString(SyntaxHighlighter.plain(source, fontSize: fontSize))
            if let ranges {
                textView.setSelectedRanges(ranges, affinity: .downstream, stillSelecting: false)
            }
            if let scrollOrigin { restoreScrollOrigin(scrollOrigin) }
            postProcess?(textView, storage)

            highlightTask?.cancel()
            highlightGeneration &+= 1
            let gen = highlightGeneration

            highlightTask = Task { [weak self] in
                let attr = await SyntaxHighlighter.highlightAsync(
                    source,
                    fileExtension: fileExtension,
                    fontSize: fontSize,
                    isDark: isDark
                )
                guard !Task.isCancelled, let self, gen == self.highlightGeneration else { return }
                guard let textView = self.textView, let storage = textView.textStorage else { return }
                let preservedRanges = preserveSelection ? textView.selectedRanges : nil
                let preservedOrigin = preserveScroll ? self.scrollView?.contentView.bounds.origin : nil
                storage.setAttributedString(attr)
                if let preservedRanges {
                    textView.setSelectedRanges(preservedRanges, affinity: .downstream, stillSelecting: false)
                }
                if let preservedOrigin { self.restoreScrollOrigin(preservedOrigin) }
                postProcess?(textView, storage)
                if let pending = self.pendingFindHighlight {
                    self.pendingFindHighlight = nil
                    textView.scrollToLineAndHighlight(
                        lineNumber: pending.lineNumber,
                        columnRange: pending.columnRange
                    )
                }
            }
        }

        /// Re-runs syntax highlighting and applies the result as an
        /// **attributes-only** change against the existing text storage. The
        /// caller must guarantee that `source` equals the current storage
        /// string (e.g. the rehighlight after a keystroke). Because text isn't
        /// replaced, AppKit doesn't push an undo entry and the user's
        /// selection/cursor stays put — fixing the cursor-jump-while-typing
        /// and the broken Cmd+Z behaviour caused by `setAttributedString`
        /// wiping the undo stack on every keystroke.
        func reapplyHighlightAttributes(
            source: String,
            fileExtension: String,
            fontSize: CGFloat,
            isDark: Bool,
            postProcess: (@MainActor (EditorTextView, NSTextStorage) -> Void)? = nil
        ) {
            guard let textView, let storage = textView.textStorage else { return }
            guard storage.string == source else { return }

            highlightTask?.cancel()
            highlightGeneration &+= 1
            let gen = highlightGeneration

            highlightTask = Task { [weak self] in
                let attr = await SyntaxHighlighter.highlightAsync(
                    source,
                    fileExtension: fileExtension,
                    fontSize: fontSize,
                    isDark: isDark
                )
                guard !Task.isCancelled, let self, gen == self.highlightGeneration else { return }
                guard let textView = self.textView, let storage = textView.textStorage else { return }
                guard storage.string == attr.string else { return }

                let fullRange = NSRange(location: 0, length: storage.length)
                storage.beginEditing()
                storage.setAttributes([:], range: fullRange)
                attr.enumerateAttributes(in: NSRange(location: 0, length: attr.length), options: []) { attrs, range, _ in
                    storage.setAttributes(attrs, range: range)
                }
                storage.endEditing()
                postProcess?(textView, storage)
            }
        }

        /// Re-applies a saved scroll origin (clamped to the document) and
        /// syncs the minimap. Used after `setAttributedString` replaces the
        /// text storage, which would otherwise let AppKit reset scroll to top.
        func restoreScrollOrigin(_ origin: NSPoint) {
            guard let scrollView else { return }
            let clipView = scrollView.contentView
            // Force layout so documentView.frame reflects the new content
            // before we ask NSClipView to clamp.
            if let textView,
               let layoutManager = textView.layoutManager,
               let textContainer = textView.textContainer {
                layoutManager.ensureLayout(for: textContainer)
            }
            let target = NSRect(origin: origin, size: clipView.bounds.size)
            let constrained = clipView.constrainBoundsRect(target)
            clipView.setBoundsOrigin(constrained.origin)
            scrollView.reflectScrolledClipView(clipView)
            minimap?.updateViewport(from: scrollView)
        }

        func installScrollObserver(name: NSNotification.Name, object: Any?) {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: name,
                object: object,
                queue: .main
            ) { [weak self] _ in
                guard let self, let scrollView = self.scrollView else { return }
                self.minimap?.updateViewport(from: scrollView)
            }
        }

        func updateMinimapMarkers(gutterDiff: GutterDiffResult, text: String) {
            guard let minimap else { return }
            minimap.totalLines = max(text.components(separatedBy: "\n").count, 1)
            minimap.setMarkers(gutterDiff.markers.mapValues(\.color))
            if let scrollView {
                minimap.updateViewport(from: scrollView)
            }
        }

        func updateMinimapMarkers(lineKinds: [Int: GitDiffLineKind], text: String) {
            guard let minimap else { return }
            minimap.totalLines = max(text.components(separatedBy: "\n").count, 1)
            minimap.setMarkers(lineKinds.mapValues(\.color))
            if let scrollView {
                minimap.updateViewport(from: scrollView)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard let textBinding = parent.text else { return }

            // Hold isEditing across the binding write AND the SwiftUI update
            // pass it triggers. Without this, `updateMode` runs while the
            // flag is already false and re-enters `applyHighlight` (line ~479)
            // for text that just changed, doing a full setAttributedString and
            // resetting cursor/selection. Clearing on the next runloop tick
            // keeps the guard active for the entire SwiftUI round-trip.
            isEditing = true
            textBinding.wrappedValue = textView.string
            DispatchQueue.main.async { [weak self] in
                self?.isEditing = false
            }

            rehighlightTask?.cancel()
            rehighlightTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self, let editorTextView = self.textView else { return }
                self.reapplyHighlightAttributes(
                    source: editorTextView.string,
                    fileExtension: self.parent.fileExtension,
                    fontSize: editorTextView.editorFontSize,
                    isDark: editorTextView.isDarkAppearance,
                    postProcess: { textView, _ in
                        textView.recomputeFolding()
                        textView.applyFoldAttributes()
                    }
                )
            }
        }

        func buildHunkLookup() {
            newLineToHunkIndex.removeAll()
            oldLineToHunkIndex.removeAll()

            for (index, hunk) in hunks.enumerated() {
                for line in hunk.lines where line.kind != nil {
                    if let newLineNumber = line.newLineNumber {
                        newLineToHunkIndex[newLineNumber] = index
                    }
                    if let oldLineNumber = line.oldLineNumber {
                        oldLineToHunkIndex[oldLineNumber] = index
                    }
                }
            }
        }

        func handleGutterClick(renderLine: Int, at point: NSPoint) {
            guard let textView, let presentation, let reference else { return }
            guard presentation.lineKinds[renderLine] != nil else { return }

            let lineNumbers = presentation.lineNumbers[renderLine]
            var hunkIndex: Int?
            if let newLineNumber = lineNumbers?.new {
                hunkIndex = newLineToHunkIndex[newLineNumber]
            }
            if hunkIndex == nil, let oldLineNumber = lineNumbers?.old {
                hunkIndex = oldLineToHunkIndex[oldLineNumber]
            }

            guard let hunkIndex, hunkIndex < hunks.count else { return }
            if case .commit = reference.stage { return }

            showContextMenu(for: hunks[hunkIndex], reference: reference, at: point, in: textView)
        }

        private func showContextMenu(for hunk: DiffHunk, reference: GitDiffReference, at point: NSPoint, in view: NSView) {
            let menu = NSMenu()

            switch reference.stage {
            case .unstaged:
                let stageItem = NSMenuItem(title: "Stage Hunk", action: #selector(menuStageHunk(_:)), keyEquivalent: "")
                stageItem.target = self
                stageItem.representedObject = hunk
                menu.addItem(stageItem)

                menu.addItem(.separator())

                let discardItem = NSMenuItem(title: "Discard Hunk", action: #selector(menuDiscardHunk(_:)), keyEquivalent: "")
                discardItem.target = self
                discardItem.representedObject = hunk
                menu.addItem(discardItem)

            case .staged:
                let unstageItem = NSMenuItem(title: "Unstage Hunk", action: #selector(menuUnstageHunk(_:)), keyEquivalent: "")
                unstageItem.target = self
                unstageItem.representedObject = hunk
                menu.addItem(unstageItem)

            case .commit:
                return
            }

            menu.popUp(positioning: nil, at: point, in: view)
        }

        @objc private func menuStageHunk(_ sender: NSMenuItem) {
            guard let hunk = sender.representedObject as? DiffHunk, let reference else { return }
            applyHunk(hunk, reverse: false, cached: true, at: reference.repositoryRootURL)
        }

        @objc private func menuUnstageHunk(_ sender: NSMenuItem) {
            guard let hunk = sender.representedObject as? DiffHunk, let reference else { return }
            applyHunk(hunk, reverse: true, cached: true, at: reference.repositoryRootURL)
        }

        @objc private func menuDiscardHunk(_ sender: NSMenuItem) {
            guard let hunk = sender.representedObject as? DiffHunk, let reference else { return }
            applyHunk(hunk, reverse: true, cached: false, at: reference.repositoryRootURL)
        }

        private func applyHunk(_ hunk: DiffHunk, reverse: Bool, cached: Bool, at root: URL) {
            Task {
                do {
                    try await GitRepository.shared.applyPatch(
                        hunk.patchText,
                        reverse: reverse,
                        cached: cached,
                        at: root
                    )
                    await onReload?()
                } catch {
                    await DiffPopoverPresenter.showError("Apply failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
