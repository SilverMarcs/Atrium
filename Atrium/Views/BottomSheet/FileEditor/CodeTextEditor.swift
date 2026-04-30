import AppKit
import SwiftUI

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
        let container = NSView()
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
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.parent = self

        guard let textView = context.coordinator.textView else { return }
        let bounds = container.bounds
        let minimapWidth = EditorTextViewConstants.minimapWidth

        let scrollViewFrame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width - minimapWidth,
            height: bounds.height
        )
        context.coordinator.scrollView?.frame = scrollViewFrame
        context.coordinator.minimap?.frame = NSRect(
            x: bounds.width - minimapWidth,
            y: 0,
            width: minimapWidth,
            height: bounds.height
        )

        updateSharedTextView(textView)

        // Until SwiftUI gives us a real width there's nothing useful to lay
        // out. Skip — we'll be called again once the parent is sized.
        guard scrollViewFrame.width > 0, let minimap = context.coordinator.minimap else { return }

        applyWrapping(textView: textView, contentWidth: scrollViewFrame.width, coordinator: context.coordinator)

        if context.coordinator.didConfigureMode {
            updateMode(textView: textView, coordinator: context.coordinator)
        } else {
            context.coordinator.didConfigureMode = true
            configureMode(textView: textView, minimap: minimap, coordinator: context.coordinator)
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
                let highlighted = SyntaxHighlighter.highlight(
                    text.wrappedValue,
                    fileExtension: fileExtension,
                    fontSize: fontSize,
                    isDark: isDark
                )
                textView.textStorage?.setAttributedString(highlighted)
                textView.recomputeFolding()
            }

            coordinator.updateMinimapMarkers(gutterDiff: gutterDiff, text: textView.string)

            if let highlightRequest {
                coordinator.lastAppliedHighlight = highlightRequest
                Task { @MainActor in
                    textView.scrollToLineAndHighlight(
                        lineNumber: highlightRequest.lineNumber,
                        columnRange: highlightRequest.columnRange
                    )
                }
            }

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

            let highlighted = SyntaxHighlighter.highlight(
                presentation.string,
                fileExtension: fileExtension,
                fontSize: fontSize,
                isDark: isDark
            )
            textView.textStorage?.setAttributedString(highlighted)
            Self.applyInlineHighlights(to: textView.textStorage, lineKinds: presentation.lineKinds)
            coordinator.lastIsDark = isDark

            coordinator.updateMinimapMarkers(lineKinds: presentation.lineKinds, text: presentation.string)

            Task { @MainActor in
                if let firstLine = presentation.firstChangedLine {
                    textView.scrollToLine(max(firstLine - 3, 1))
                }
            }
        }

        minimap.totalLines = max(textView.string.components(separatedBy: "\n").count, 1)
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

            if let text, !coordinator.isEditing,
               textView.string != text.wrappedValue || colorSchemeChanged || documentChanged {
                let ranges = textView.selectedRanges
                let highlighted = SyntaxHighlighter.highlight(
                    text.wrappedValue,
                    fileExtension: fileExtension,
                    fontSize: fontSize,
                    isDark: isDark
                )
                textView.textStorage?.setAttributedString(highlighted)
                textView.setSelectedRanges(ranges, affinity: .downstream, stillSelecting: false)
                textView.recomputeFolding()
                textView.applyFoldAttributes()
            }

            if let highlightRequest, highlightRequest != coordinator.lastAppliedHighlight {
                coordinator.lastAppliedHighlight = highlightRequest
                Task { @MainActor in
                    textView.scrollToLineAndHighlight(
                        lineNumber: highlightRequest.lineNumber,
                        columnRange: highlightRequest.columnRange
                    )
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

            coordinator.presentation = presentation
            coordinator.hunks = hunks
            coordinator.reference = reference
            coordinator.onReload = onReload
            coordinator.buildHunkLookup()

            if textView.string != presentation.string || colorSchemeChanged {
                let highlighted = SyntaxHighlighter.highlight(
                    presentation.string,
                    fileExtension: fileExtension,
                    fontSize: fontSize,
                    isDark: isDark
                )
                textView.textStorage?.setAttributedString(highlighted)
                Self.applyInlineHighlights(to: textView.textStorage, lineKinds: presentation.lineKinds)
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
        var lastDocumentID: AnyHashable?
        var lastWrapLines: Bool?
        var lastWrapContentWidth: CGFloat?
        var lastIsDark: Bool?
        private var rehighlightTask: Task<Void, Never>?

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

            isEditing = true
            textBinding.wrappedValue = textView.string
            isEditing = false

            rehighlightTask?.cancel()
            rehighlightTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self, let editorTextView = self.textView else { return }

                let source = editorTextView.string
                let fileExtension = self.parent.fileExtension
                let selectedRanges = editorTextView.selectedRanges
                let highlighted = SyntaxHighlighter.highlight(
                    source,
                    fileExtension: fileExtension,
                    fontSize: editorTextView.editorFontSize,
                    isDark: editorTextView.isDarkAppearance
                )

                await MainActor.run {
                    editorTextView.textStorage?.setAttributedString(highlighted)
                    editorTextView.setSelectedRanges(selectedRanges, affinity: .downstream, stillSelecting: false)
                    editorTextView.recomputeFolding()
                    editorTextView.applyFoldAttributes()
                }
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
