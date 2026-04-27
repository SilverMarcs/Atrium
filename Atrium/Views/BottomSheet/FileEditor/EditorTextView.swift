import AppKit

enum EditorTextViewConstants {
    static let gutterWidth: CGFloat = 48
    static let markerBarWidth: CGFloat = 3
    static let foldColumnWidth: CGFloat = 12
    static let minimapWidth: CGFloat = 16

    // Diff mode gutter layout (single line number, no fold column)
    static let diffGutterWidth: CGFloat = 52
    static let diffNumEndX: CGFloat = 42
    static let diffMarkerX: CGFloat = 46
}

// MARK: - Editor Text View with Gutter

final class EditorTextView: NSTextView {
    var gutterDiff: GutterDiffResult = .empty
    var fileExtension: String = ""
    let foldingManager = FoldingManager()

    // Diff mode
    var diffLineKinds: [Int: GitDiffLineKind] = [:]
    var diffLineNumbers: [Int: GitDiffLineNumbers] = [:]
    var isDiffMode: Bool { !diffLineKinds.isEmpty }
    var diffGutterClickHandler: ((Int, NSPoint) -> Void)?
    var repositoryRootURL: URL?
    var gutterDiffReloadHandler: (() async -> Void)?
    var saveHandler: (() -> Void)?

    var editorFontSize: CGFloat = 12
    var lineNumberFontSize: CGFloat = 11

    /// Whether the view is currently rendering with a dark appearance. Used by
    /// `toggleFold` and the post-edit re-highlight so syntax colors stay in sync
    /// with the system appearance without routing through SwiftUI.
    var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    private var lineNumberFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: lineNumberFontSize, weight: .medium) }
    private let indentUnit = "    " // 4 spaces

    // MARK: - Current Line Highlight

    private var currentLineHighlightColor: NSColor {
        NSColor.labelColor.withAlphaComponent(0.06)
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
        needsDisplay = true
    }

    /// Re-apply syntax highlighting with the new appearance's palette whenever
    /// the system toggles light/dark mode. Diff mode re-applies inline
    /// add/remove highlights from its SwiftUI owner, so we skip diff here and
    /// let `CodeTextEditor.updateNSView` (driven by `@Environment(\.colorScheme)`)
    /// handle that path.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard !isDiffMode, let textStorage, textStorage.length > 0 else {
            needsDisplay = true
            return
        }
        let source = string
        let ranges = selectedRanges
        let highlighted = SyntaxHighlighter.highlight(
            source,
            fileExtension: fileExtension,
            fontSize: editorFontSize,
            isDark: isDarkAppearance
        )
        textStorage.setAttributedString(highlighted)
        setSelectedRanges(ranges, affinity: .downstream, stillSelecting: false)
        applyFoldAttributes()
        needsDisplay = true
    }

    private var currentCursorLine: Int {
        let text = string as NSString
        guard text.length > 0 else { return 1 }
        let loc = min(selectedRange().location, text.length)
        let pre = text.substring(to: loc)
        return pre.components(separatedBy: "\n").count
    }

    // MARK: - Bracket Matching

    private static let bracketPairs: [(open: Character, close: Character)] = [
        ("{", "}"), ("(", ")"), ("[", "]"),
    ]

    /// Returns the indices of the matched bracket pair near the cursor, if any.
    private func matchedBracketIndices() -> (Int, Int)? {
        let text = string
        let chars = Array(text.unicodeScalars)
        guard !chars.isEmpty else { return nil }
        let loc = selectedRange().location

        // Check character before cursor and at cursor
        for offset in [loc - 1, loc] {
            guard offset >= 0 && offset < chars.count else { continue }
            let c = Character(chars[offset])

            for pair in Self.bracketPairs {
                if c == pair.open {
                    if let match = Self.findMatchingClose(in: chars, from: offset, open: pair.open, close: pair.close) {
                        return (offset, match)
                    }
                } else if c == pair.close {
                    if let match = Self.findMatchingOpen(in: chars, from: offset, open: pair.open, close: pair.close) {
                        return (match, offset)
                    }
                }
            }
        }
        return nil
    }

    private static func findMatchingClose(in chars: [Unicode.Scalar], from: Int, open: Character, close: Character) -> Int? {
        var depth = 1
        let openScalar = open.unicodeScalars.first!
        let closeScalar = close.unicodeScalars.first!
        for i in (from + 1)..<chars.count {
            if chars[i] == openScalar { depth += 1 }
            else if chars[i] == closeScalar { depth -= 1; if depth == 0 { return i } }
        }
        return nil
    }

    private static func findMatchingOpen(in chars: [Unicode.Scalar], from: Int, open: Character, close: Character) -> Int? {
        var depth = 1
        let openScalar = open.unicodeScalars.first!
        let closeScalar = close.unicodeScalars.first!
        for i in stride(from: from - 1, through: 0, by: -1) {
            if chars[i] == closeScalar { depth += 1 }
            else if chars[i] == openScalar { depth -= 1; if depth == 0 { return i } }
        }
        return nil
    }

    private func drawBracketHighlights() {
        guard let layoutManager, let textContainer else { return }
        guard let (openIdx, closeIdx) = matchedBracketIndices() else { return }

        let containerOrigin = textContainerOrigin
        let highlightColor = NSColor.labelColor.withAlphaComponent(0.15)
        let borderColor = NSColor.labelColor.withAlphaComponent(0.3)

        for idx in [openIdx, closeIdx] {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: idx, length: 1), actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound else { continue }
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += containerOrigin.x
            rect.origin.y += containerOrigin.y
            let rounded = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 0), xRadius: 2, yRadius: 2)
            highlightColor.setFill()
            rounded.fill()
            borderColor.setStroke()
            rounded.lineWidth = 0.5
            rounded.stroke()
        }
    }

    // MARK: - Folding

    func recomputeFolding() {
        foldingManager.recompute(for: string)
    }

    private func toggleFold(at lineNumber: Int) {
        foldingManager.toggleFold(lineNumber)

        // Re-highlight to reset attributes, then re-apply fold hiding
        let source = string
        let ranges = selectedRanges
        let highlighted = SyntaxHighlighter.highlight(
            source,
            fileExtension: fileExtension,
            fontSize: editorFontSize,
            isDark: isDarkAppearance
        )
        textStorage?.setAttributedString(highlighted)
        setSelectedRanges(ranges, affinity: .downstream, stillSelecting: false)
        applyFoldAttributes()
        needsDisplay = true
    }

    /// Applies hidden text attributes to all currently-folded regions.
    /// Call after syntax highlighting to layer fold hiding on top.
    func applyFoldAttributes() {
        guard let textStorage else { return }
        let text = string as NSString
        guard text.length > 0 else { return }

        let hiddenStyle = NSMutableParagraphStyle()
        hiddenStyle.maximumLineHeight = 0.001
        hiddenStyle.minimumLineHeight = 0.001
        hiddenStyle.lineSpacing = 0
        hiddenStyle.paragraphSpacing = 0
        hiddenStyle.paragraphSpacingBefore = 0

        let hiddenAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 0.001, weight: .regular),
            .foregroundColor: NSColor.clear,
            .paragraphStyle: hiddenStyle,
        ]

        for startLine in foldingManager.foldedStartLines {
            guard let region = foldingManager.region(startingAt: startLine) else { continue }
            let hideFromLine = region.startLine + 1
            guard hideFromLine <= region.endLine else { continue }
            guard region.startLine < foldingManager.lineStarts.count else { continue }

            let startIdx = foldingManager.lineStarts[region.startLine] // start of hideFromLine
            let endIdx = region.endLine < foldingManager.lineStarts.count
                ? foldingManager.lineStarts[region.endLine]
                : text.length
            let range = NSRange(location: startIdx, length: endIdx - startIdx)
            guard range.length > 0, NSMaxRange(range) <= text.length else { continue }

            textStorage.addAttributes(hiddenAttrs, range: range)
        }
    }

    // MARK: - Auto-Close Pairs

    private static let autoClosePairs: [Character: Character] = [
        "{": "}", "(": ")", "[": "]", "\"": "\"", "'": "'",
    ]
    private static let openBrackets: Set<Character> = ["{", "(", "["]
    private static let closeBrackets: Set<Character> = ["}", ")", "]"]

    private func charAt(_ index: Int) -> Character? {
        let text = string as NSString
        guard index >= 0, index < text.length else { return nil }
        let uni = text.character(at: index)
        return Character(UnicodeScalar(uni)!)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let str = string as? String, str.count == 1, let char = str.first else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        let loc = selectedRange().location

        // Typing a closing bracket or quote that already exists right after cursor — skip over it
        if (Self.closeBrackets.contains(char) || char == "\"" || char == "'"),
           let nextChar = charAt(loc), nextChar == char {
            setSelectedRange(NSRange(location: loc + 1, length: 0))
            return
        }

        // Auto-close opening brackets
        if Self.openBrackets.contains(char), let closer = Self.autoClosePairs[char] {
            super.insertText(string, replacementRange: replacementRange)
            let afterLoc = selectedRange().location
            super.insertText(String(closer), replacementRange: NSRange(location: afterLoc, length: 0))
            setSelectedRange(NSRange(location: afterLoc, length: 0))
            return
        }

        // Auto-close quotes (only if not preceded by alphanumeric, suggesting end of word)
        if (char == "\"" || char == "'"), let closer = Self.autoClosePairs[char] {
            let shouldAutoClose: Bool
            if let prevChar = charAt(loc - 1) {
                shouldAutoClose = !prevChar.isLetter && !prevChar.isNumber
            } else {
                shouldAutoClose = true
            }

            if shouldAutoClose {
                super.insertText(string, replacementRange: replacementRange)
                let afterLoc = selectedRange().location
                super.insertText(String(closer), replacementRange: NSRange(location: afterLoc, length: 0))
                setSelectedRange(NSRange(location: afterLoc, length: 0))
                return
            }
        }

        super.insertText(string, replacementRange: replacementRange)
    }

    override func deleteBackward(_ sender: Any?) {
        let loc = selectedRange().location
        // Delete both characters of an empty auto-close pair
        if let prev = charAt(loc - 1), let next = charAt(loc),
           let closer = Self.autoClosePairs[prev], closer == next {
            super.deleteBackward(sender)
            deleteForward(sender)
            return
        }

        super.deleteBackward(sender)
    }

    // MARK: - Smart Editing

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let loc = selectedRange().location

        // Find current line and its leading whitespace
        let lineRange = text.lineRange(for: NSRange(location: loc, length: 0))
        let line = text.substring(with: lineRange)
        let leadingWhitespace = String(line.prefix(while: { $0 == " " || $0 == "\t" }))

        // Check if the character before the cursor is an opening brace
        let trimmed = text.substring(with: NSRange(location: lineRange.location, length: loc - lineRange.location))
            .trimmingCharacters(in: .whitespaces)
        let opensBlock = trimmed.hasSuffix("{")
        let extraIndent = opensBlock ? indentUnit : ""

        // Special case: cursor between {} — expand to three lines
        if opensBlock, let nextChar = charAt(loc), nextChar == "}" {
            super.insertNewline(sender)
            let indentedLine = leadingWhitespace + indentUnit
            let closingLine = "\n" + leadingWhitespace
            insertText(indentedLine + closingLine, replacementRange: selectedRange())
            // Place cursor at end of indented line
            let cursorLoc = selectedRange().location - closingLine.count
            setSelectedRange(NSRange(location: cursorLoc, length: 0))
            return
        }

        super.insertNewline(sender)
        insertText(leadingWhitespace + extraIndent, replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else {
            insertText(indentUnit, replacementRange: range)
            return
        }
        indentSelection(indent: true)
    }

    override func insertBacktab(_ sender: Any?) {
        indentSelection(indent: false)
    }

    private func indentSelection(indent: Bool) {
        let text = string as NSString
        let range = selectedRange()
        let hadSelection = range.length > 0
        let lineRange = text.lineRange(for: range)
        let linesStr = text.substring(with: lineRange)
        let lines = linesStr.components(separatedBy: "\n")

        var newLines: [String] = []
        var firstLineDelta = 0
        for (i, line) in lines.enumerated() {
            // Skip the trailing empty component from lineRange
            if i == lines.count - 1 && line.isEmpty {
                newLines.append(line)
                continue
            }
            if indent {
                newLines.append(indentUnit + line)
                if i == 0 { firstLineDelta = indentUnit.count }
            } else {
                // Remove up to one indent unit from the start
                var removed = 0
                var start = line.startIndex
                while removed < indentUnit.count, start < line.endIndex, line[start] == " " {
                    start = line.index(after: start)
                    removed += 1
                }
                newLines.append(String(line[start...]))
                if i == 0 { firstLineDelta = -removed }
            }
        }

        let replacement = newLines.joined(separator: "\n")
        if shouldChangeText(in: lineRange, replacementString: replacement) {
            replaceCharacters(in: lineRange, with: replacement)
            didChangeText()
            if hadSelection {
                setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
            } else {
                let newLoc = max(lineRange.location, range.location + firstLineDelta)
                setSelectedRange(NSRange(location: newLoc, length: 0))
            }
        }
    }

    // MARK: - Comment Toggle (Cmd+/)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "/" {
            toggleComment()
            return true
        }
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.charactersIgnoringModifiers == "s",
           let saveHandler {
            saveHandler()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private var commentPrefix: String {
        switch fileExtension {
        case "py", "rb", "sh", "bash", "zsh", "yml", "yaml", "toml":
            return "#"
        case "html", "xml", "svg":
            return "//" // simplified — full HTML comments are block-level
        default:
            return "//"
        }
    }

    private func toggleComment() {
        let text = string as NSString
        let range = selectedRange()
        let hadSelection = range.length > 0
        let lineRange = text.lineRange(for: range)
        let linesStr = text.substring(with: lineRange)
        let lines = linesStr.components(separatedBy: "\n")
        let prefix = commentPrefix + " "

        // Determine if we're commenting or uncommenting:
        // If all non-empty lines are commented, uncomment. Otherwise, comment.
        let nonEmptyLines = lines.enumerated().filter { i, line in
            !(i == lines.count - 1 && line.isEmpty) && !line.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let allCommented = nonEmptyLines.allSatisfy { $0.1.trimmingCharacters(in: .init(charactersIn: " \t")).hasPrefix(prefix.trimmingCharacters(in: .whitespaces)) }

        var newLines: [String] = []
        var firstLineDelta = 0
        for (i, line) in lines.enumerated() {
            if i == lines.count - 1 && line.isEmpty {
                newLines.append(line)
                continue
            }
            if allCommented {
                // Remove comment prefix (handle both "// " and "//")
                let trimPrefix = commentPrefix
                if let r = line.range(of: trimPrefix + " ") {
                    var modified = line
                    let removedCount = line.distance(from: r.lowerBound, to: r.upperBound)
                    modified.removeSubrange(r)
                    newLines.append(modified)
                    if i == 0 { firstLineDelta = -removedCount }
                } else if let r = line.range(of: trimPrefix) {
                    var modified = line
                    let removedCount = line.distance(from: r.lowerBound, to: r.upperBound)
                    modified.removeSubrange(r)
                    newLines.append(modified)
                    if i == 0 { firstLineDelta = -removedCount }
                } else {
                    newLines.append(line)
                }
            } else {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    newLines.append(line)
                } else {
                    // Insert comment at the first non-whitespace position
                    let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                    let rest = String(line.dropFirst(indent.count))
                    newLines.append(indent + prefix + rest)
                    if i == 0 { firstLineDelta = prefix.count }
                }
            }
        }

        let replacement = newLines.joined(separator: "\n")
        if shouldChangeText(in: lineRange, replacementString: replacement) {
            replaceCharacters(in: lineRange, with: replacement)
            didChangeText()
            if hadSelection {
                setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
            } else {
                let newLoc = max(lineRange.location, range.location + firstLineDelta)
                setSelectedRange(NSRange(location: newLoc, length: 0))
            }
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard let layoutManager, let textContainer else { return }

        if isDiffMode {
            drawDiffBackground(in: rect, layoutManager: layoutManager, textContainer: textContainer)
        } else {
            drawEditorBackground(in: rect, layoutManager: layoutManager, textContainer: textContainer)
        }
    }

    // MARK: - Diff Mode Background

    private func drawDiffBackground(in rect: NSRect, layoutManager: NSLayoutManager, textContainer: NSTextContainer) {
        let constants = EditorTextViewConstants.self
        let containerOrigin = textContainerOrigin
        let text = string as NSString
        guard text.length > 0 else { return }

        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        let lineNumAttrs: [NSAttributedString.Key: Any] = [
            .font: lineNumberFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        var startLineNumber = 1
        if visibleCharRange.location > 0 {
            let preText = text.substring(to: visibleCharRange.location)
            startLineNumber = preText.components(separatedBy: "\n").count
        }

        let bgWidth = max(bounds.width, enclosingScrollView?.contentSize.width ?? bounds.width) - constants.diffGutterWidth

        var lineNumber = startLineNumber
        var charIndex = visibleCharRange.location
        let endChar = NSMaxRange(visibleCharRange)

        while charIndex <= endChar && charIndex < text.length {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let lineKind = diffLineKinds[lineNumber]
            let lineNums = diffLineNumbers[lineNumber]

            var firstFragmentRect: NSRect?
            enumerateLineFragmentRects(
                for: lineRange,
                layoutManager: layoutManager,
                containerOrigin: containerOrigin
            ) { fragmentRect in
                let isVisible = fragmentRect.height > 1
                    && fragmentRect.minY + fragmentRect.height >= rect.minY
                    && fragmentRect.minY <= rect.maxY
                guard isVisible else { return }

                if firstFragmentRect == nil { firstFragmentRect = fragmentRect }

                guard let kind = lineKind else { return }

                // Line background tint — fill across full content width per fragment.
                let bgColor = kind.color.withAlphaComponent(0.12)
                bgColor.setFill()
                NSRect(
                    x: constants.diffGutterWidth,
                    y: fragmentRect.minY,
                    width: bgWidth,
                    height: fragmentRect.height
                ).fill()

                // Gutter tint per fragment.
                let gutterBg = kind.color.withAlphaComponent(0.06)
                gutterBg.setFill()
                NSRect(
                    x: 0,
                    y: fragmentRect.minY,
                    width: constants.diffGutterWidth,
                    height: fragmentRect.height
                ).fill()

                // Marker bar per fragment.
                kind.color.setFill()
                NSRect(
                    x: constants.diffMarkerX,
                    y: fragmentRect.minY,
                    width: 3,
                    height: fragmentRect.height
                ).fill()
            }

            // Draw the line number once on the first visual fragment.
            if let firstRect = firstFragmentRect {
                let yCenter = firstRect.minY + (firstRect.height - ("0" as NSString).size(withAttributes: lineNumAttrs).height) / 2
                let lineNum = lineNums?.new ?? lineNums?.old
                if let num = lineNum {
                    let str = "\(num)" as NSString
                    let size = str.size(withAttributes: lineNumAttrs)
                    str.draw(at: NSPoint(x: constants.diffNumEndX - size.width, y: yCenter), withAttributes: lineNumAttrs)
                }
            }

            lineNumber += 1
            let nextIndex = NSMaxRange(lineRange)
            if nextIndex <= charIndex { break }
            charIndex = nextIndex
        }
    }

    /// Enumerates the line fragment rects (in text-view coordinates) for every
    /// visual fragment that the given character range occupies. When soft-wrap
    /// is on a single logical line can span multiple fragments — this lets
    /// callers paint backgrounds, gutter tints, and marker bars on every visual
    /// row instead of just the first.
    private func enumerateLineFragmentRects(
        for charRange: NSRange,
        layoutManager: NSLayoutManager,
        containerOrigin: NSPoint,
        body: @escaping (NSRect) -> Void
    ) {
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound else { return }

        if glyphRange.length == 0 {
            var effective = NSRange()
            let fragRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: &effective)
            guard fragRect != .zero else { return }
            var rect = fragRect
            rect.origin.x += containerOrigin.x
            rect.origin.y += containerOrigin.y
            body(rect)
            return
        }

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, _, _ in
            var rect = fragmentRect
            rect.origin.x += containerOrigin.x
            rect.origin.y += containerOrigin.y
            body(rect)
        }
    }

    // MARK: - Editor Mode Background

    private func drawEditorBackground(in rect: NSRect, layoutManager: NSLayoutManager, textContainer: NSTextContainer) {
        let gutterWidth = EditorTextViewConstants.gutterWidth
        let markerBarWidth = EditorTextViewConstants.markerBarWidth
        let foldColWidth = EditorTextViewConstants.foldColumnWidth
        let containerOrigin = textContainerOrigin
        let text = string as NSString

        let lineNumAttrs: [NSAttributedString.Key: Any] = [
            .font: lineNumberFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let lineNumEndX = gutterWidth - foldColWidth - markerBarWidth - 6

        if text.length == 0 {
            var fragmentRect = layoutManager.extraLineFragmentRect
            if fragmentRect == .zero {
                let resolvedFont = font ?? NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .regular)
                let lineHeight = layoutManager.defaultLineHeight(for: resolvedFont)
                fragmentRect = NSRect(x: 0, y: 0, width: 0, height: lineHeight)
            }
            let lineY = fragmentRect.minY + containerOrigin.y
            let lineHeight = fragmentRect.height

            currentLineHighlightColor.setFill()
            NSRect(x: 0, y: lineY, width: bounds.width, height: lineHeight).fill()

            let numStr = "1" as NSString
            let size = numStr.size(withAttributes: lineNumAttrs)
            let x = lineNumEndX - size.width
            let y = lineY + (lineHeight - size.height) / 2
            numStr.draw(at: NSPoint(x: x, y: y), withAttributes: lineNumAttrs)
            return
        }

        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        let foldBadgeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        // Count lines before visible range
        var startLineNumber = 1
        if visibleCharRange.location > 0 {
            let preText = text.substring(to: visibleCharRange.location)
            startLineNumber = preText.components(separatedBy: "\n").count
        }

        let markerBarX = gutterWidth - foldColWidth - markerBarWidth - 1
        let foldCenterX = gutterWidth - foldColWidth / 2

        let cursorLine = currentCursorLine

        var lineNumber = startLineNumber
        var charIndex = visibleCharRange.location
        let endChar = NSMaxRange(visibleCharRange)

        while charIndex <= endChar && charIndex < text.length {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)

            let isHidden = foldingManager.isLineHidden(lineNumber)

            if glyphRange.location != NSNotFound && !isHidden {
                var firstFragmentRect: NSRect?

                // Enumerate all visual fragments for this logical line so that
                // backgrounds and markers span every wrapped row.
                enumerateLineFragmentRects(
                    for: lineRange,
                    layoutManager: layoutManager,
                    containerOrigin: containerOrigin
                ) { [self] fragmentRect in
                    let isVisible = fragmentRect.height > 1
                        && fragmentRect.minY + fragmentRect.height >= rect.minY
                        && fragmentRect.minY <= rect.maxY
                    guard isVisible else { return }

                    if firstFragmentRect == nil { firstFragmentRect = fragmentRect }

                    // Current line highlight — all visual rows.
                    if lineNumber == cursorLine {
                        currentLineHighlightColor.setFill()
                        NSRect(x: 0, y: fragmentRect.minY, width: bounds.width, height: fragmentRect.height).fill()
                    }

                    // Git change marker bar — all visual rows.
                    if let marker = gutterDiff.markers[lineNumber] {
                        marker.color.setFill()
                        NSRect(x: markerBarX, y: fragmentRect.minY, width: markerBarWidth, height: fragmentRect.height).fill()
                    }
                }

                if let firstRect = firstFragmentRect {
                    // Draw line number right-aligned on first fragment only.
                    let numStr = "\(lineNumber)" as NSString
                    let size = numStr.size(withAttributes: lineNumAttrs)
                    let x = lineNumEndX - size.width
                    let y = firstRect.minY + (firstRect.height - size.height) / 2
                    numStr.draw(at: NSPoint(x: x, y: y), withAttributes: lineNumAttrs)

                    // Draw fold indicator on first fragment only.
                    if foldingManager.isFoldable(lineNumber) {
                        let isFolded = foldingManager.isFolded(lineNumber)
                        let cy = firstRect.minY + firstRect.height / 2

                        let triangle = NSBezierPath()
                        if isFolded {
                            triangle.move(to: NSPoint(x: foldCenterX - 2.5, y: cy - 4))
                            triangle.line(to: NSPoint(x: foldCenterX - 2.5, y: cy + 4))
                            triangle.line(to: NSPoint(x: foldCenterX + 3, y: cy))
                        } else {
                            triangle.move(to: NSPoint(x: foldCenterX - 4, y: cy - 2.5))
                            triangle.line(to: NSPoint(x: foldCenterX + 4, y: cy - 2.5))
                            triangle.line(to: NSPoint(x: foldCenterX, y: cy + 3))
                        }
                        triangle.close()
                        NSColor.tertiaryLabelColor.setFill()
                        triangle.fill()

                        if isFolded {
                            let closing = foldingManager.region(startingAt: lineNumber)?.closing ?? ""
                            let badgeText = " ••• " as NSString
                            let usedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                            let badgeSize = badgeText.size(withAttributes: foldBadgeAttrs)
                            let badgeX = containerOrigin.x + usedRect.maxX + 2
                            let badgeY = firstRect.minY + (firstRect.height - badgeSize.height) / 2
                            badgeText.draw(at: NSPoint(x: badgeX, y: badgeY), withAttributes: foldBadgeAttrs)

                            // Render the closing token in the editor's own font + color so
                            // it visually matches the opening bracket on this line.
                            if !closing.isEmpty {
                                var closingAttrs: [NSAttributedString.Key: Any] = [
                                    .font: font ?? NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .regular),
                                    .foregroundColor: textColor ?? NSColor.labelColor,
                                ]
                                if let textStorage, lineRange.length > 0 {
                                    var sampleIdx = lineRange.location + lineRange.length - 1
                                    while sampleIdx > lineRange.location {
                                        let ch = text.character(at: sampleIdx)
                                        if ch != 10 && ch != 13 { break }
                                        sampleIdx -= 1
                                    }
                                    if sampleIdx >= 0 && sampleIdx < textStorage.length {
                                        let storedAttrs = textStorage.attributes(at: sampleIdx, effectiveRange: nil)
                                        if let f = storedAttrs[.font] as? NSFont { closingAttrs[.font] = f }
                                        if let c = storedAttrs[.foregroundColor] as? NSColor { closingAttrs[.foregroundColor] = c }
                                    }
                                }
                                let closingNS = (" " + closing) as NSString
                                let closingSize = closingNS.size(withAttributes: closingAttrs)
                                let closingX = badgeX + badgeSize.width
                                let closingY = firstRect.minY + (firstRect.height - closingSize.height) / 2
                                closingNS.draw(at: NSPoint(x: closingX, y: closingY), withAttributes: closingAttrs)
                            }
                        }
                    }
                }
            }

            lineNumber += 1
            let nextIndex = NSMaxRange(lineRange)
            if nextIndex <= charIndex { break }
            charIndex = nextIndex
        }

        // Draw bracket matching highlights on top
        drawBracketHighlights()
    }

    private func drawingLineRect(
        for glyphRange: NSRange,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        containerOrigin: NSPoint
    ) -> NSRect {
        let glyphIndex = min(glyphRange.location, max(layoutManager.numberOfGlyphs - 1, 0))
        var lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        lineRect.origin.x += containerOrigin.x
        lineRect.origin.y += containerOrigin.y
        return lineRect
    }

    // MARK: - Scroll to line and highlight match

    func scrollToLineAndHighlight(lineNumber: Int, columnRange: Range<Int>) {
        let text = string as NSString
        guard text.length > 0 else { return }

        // Find the character range for the target line
        var currentLine = 1
        var lineStart = 0
        while currentLine < lineNumber && lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            lineStart = NSMaxRange(lineRange)
            currentLine += 1
        }

        guard currentLine == lineNumber else { return }

        let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))

        // Calculate the match range within this line
        let matchLocation = lineStart + columnRange.lowerBound
        let matchLength = columnRange.upperBound - columnRange.lowerBound
        let matchRange = NSRange(
            location: min(matchLocation, text.length),
            length: min(matchLength, text.length - min(matchLocation, text.length))
        )

        // Select the match range and scroll to it
        setSelectedRange(matchRange)
        scrollRangeToVisible(lineRange)

        // Show native find indicator (yellow bounce, like CotEditor)
        if matchRange.length > 0 {
            showFindIndicator(for: matchRange)
        }
    }

    // MARK: - Click handling for gutter diff popover

    // MARK: - Scroll to line

    func scrollToLine(_ lineNumber: Int) {
        let text = string as NSString
        guard text.length > 0 else { return }
        var currentLine = 1
        var lineStart = 0
        while currentLine < lineNumber && lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            lineStart = NSMaxRange(lineRange)
            currentLine += 1
        }
        let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
        scrollRangeToVisible(lineRange)
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)

        // Diff mode gutter click
        if isDiffMode {
            guard localPoint.x < EditorTextViewConstants.diffGutterWidth else {
                super.mouseDown(with: event)
                return
            }
            guard let layoutManager, let textContainer else { return }
            let text = string as NSString
            guard text.length > 0 else { return }
            let containerOrigin = textContainerOrigin
            let textPoint = NSPoint(x: containerOrigin.x, y: localPoint.y - containerOrigin.y)
            let charIndex = layoutManager.characterIndex(
                for: textPoint, in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            let preText = text.substring(to: min(charIndex, text.length))
            let clickedLine = preText.components(separatedBy: "\n").count
            diffGutterClickHandler?(clickedLine, localPoint)
            return
        }

        let gutterWidth = EditorTextViewConstants.gutterWidth
        let foldColStart = gutterWidth - EditorTextViewConstants.foldColumnWidth

        // Only intercept clicks in the gutter area
        guard localPoint.x < gutterWidth else {
            super.mouseDown(with: event)
            return
        }

        guard let layoutManager, let textContainer else { return }

        let text = string as NSString
        guard text.length > 0 else { return }

        let containerOrigin = textContainerOrigin
        let textPoint = NSPoint(x: containerOrigin.x, y: localPoint.y - containerOrigin.y)

        let charIndex = layoutManager.characterIndex(
            for: textPoint, in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )

        let preText = text.substring(to: min(charIndex, text.length))
        let clickedLine = preText.components(separatedBy: "\n").count

        // Fold indicator click
        if localPoint.x >= foldColStart && foldingManager.isFoldable(clickedLine) {
            toggleFold(at: clickedLine)
            return
        }

        // Diff popover click
        guard gutterDiff.markers[clickedLine] != nil else { return }

        let markerStage = gutterDiff.markers[clickedLine]?.stage

        guard let hunk = gutterDiff.hunks.first(where: { hunk in
            if let markerStage, hunk.stage != markerStage {
                return false
            }
            if hunk.kind == .deleted {
                return clickedLine == max(hunk.newStart, 1)
            } else {
                return clickedLine >= hunk.newStart && clickedLine < hunk.newStart + hunk.newCount
            }
        }) else { return }

        DiffPopoverPresenter.showDiffPopover(
            for: hunk,
            at: localPoint,
            in: self,
            repositoryRootURL: repositoryRootURL,
            onReload: gutterDiffReloadHandler
        )
    }
}
