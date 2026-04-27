import AppKit

final class MarkdownPlainTextView: NSTextView {
    let markdownTextStorage = NSTextStorage()
    let markdownLayoutManager = MarkdownLayoutManager()
    let markdownTextContainer = NSTextContainer()

    init() {
        markdownLayoutManager.delegate = markdownLayoutManager
        markdownLayoutManager.addTextContainer(markdownTextContainer)
        markdownTextStorage.addLayoutManager(markdownLayoutManager)
        super.init(frame: .zero, textContainer: markdownTextContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        markdownAncestorMenu(from: self)
    }

    override func copy(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0 else { return }

        let tableBlocks = markdownLayoutManager.tableBlocks
        let intersecting = tableBlocks.filter {
            NSIntersectionRange($0.range, selection).length > 0
        }.sorted { $0.range.location < $1.range.location }

        let hasThematicBreaks = Self.selectionContainsThematicBreak(
            in: markdownTextStorage,
            range: selection
        )

        guard !intersecting.isEmpty || hasThematicBreaks else {
            super.copy(sender)
            return
        }

        let fullString = markdownTextStorage.string as NSString
        let selEnd = selection.location + selection.length
        var plainText = ""
        var html = ""
        var cursor = selection.location

        for table in intersecting {
            let tableStart = table.range.location
            let tableEnd = table.range.location + table.range.length

            if cursor < tableStart {
                let pre = fullString.substring(with: NSRange(location: cursor, length: min(tableStart, selEnd) - cursor))
                plainText += pre
                html += Self.htmlEscaped(pre)
            }

            let (tablePlain, tableHTML) = Self.tablePasteboardRepresentations(from: table.content)
            plainText += tablePlain
            html += tableHTML
            cursor = min(tableEnd, selEnd)
        }

        if cursor < selEnd {
            let post = fullString.substring(with: NSRange(location: cursor, length: selEnd - cursor))
            plainText += post
            html += Self.htmlEscaped(post)
        }

        if hasThematicBreaks {
            plainText = Self.replaceThematicBreakCharacters(
                in: plainText,
                storage: markdownTextStorage,
                selectionRange: selection
            )
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plainText, forType: .string)
        if let htmlData = html.data(using: .utf8) {
            pasteboard.setData(htmlData, forType: .html)
        }
    }

    private static func selectionContainsThematicBreak(
        in storage: NSTextStorage,
        range: NSRange
    ) -> Bool {
        var found = false
        storage.enumerateAttribute(.markdownThematicBreak, in: range) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private static func replaceThematicBreakCharacters(
        in plainText: String,
        storage: NSTextStorage,
        selectionRange: NSRange
    ) -> String {
        // Collect character offsets within the selection that are thematic breaks
        var breakOffsets: [Int] = []
        storage.enumerateAttribute(.markdownThematicBreak, in: selectionRange) { value, range, _ in
            guard value != nil else { return }
            for i in 0..<range.length {
                breakOffsets.append(range.location + i - selectionRange.location)
            }
        }

        guard !breakOffsets.isEmpty else { return plainText }

        let breakSet = Set(breakOffsets)
        var result = ""
        var utf16Offset = 0
        for char in plainText {
            if breakSet.contains(utf16Offset) && char == "\u{200B}" {
                result += "---"
            } else {
                result += String(char)
            }
            utf16Offset += char.utf16.count
        }
        return result
    }

    private static func tablePasteboardRepresentations(from rawMarkdown: String) -> (plain: String, html: String) {
        let lines = rawMarkdown.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return (rawMarkdown, htmlEscaped(rawMarkdown)) }

        let headers = MarkdownTableBlock.parseCells(from: lines[0])
        let bodyLines = lines.dropFirst(MarkdownTableBlock.isSeparatorLine(lines[1]) ? 2 : 1)
        let rows = bodyLines.map { MarkdownTableBlock.parseCells(from: $0) }

        var plain = headers.joined(separator: "\t")
        for row in rows {
            plain += "\n" + row.joined(separator: "\t")
        }

        var html = "<table><thead><tr>"
        for header in headers {
            html += "<th>\(htmlEscaped(header))</th>"
        }
        html += "</tr></thead><tbody>"
        for row in rows {
            html += "<tr>"
            for cell in row {
                html += "<td>\(htmlEscaped(cell))</td>"
            }
            html += "</tr>"
        }
        html += "</tbody></table>"

        return (plain, html)
    }

    private static func htmlEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    func update(document: MarkdownRenderedDocument) {
        markdownLayoutManager.codeBlocks = document.codeBlocks
        markdownLayoutManager.quoteBlocks = document.quoteBlocks
        markdownLayoutManager.tableBlocks = document.tableBlocks
        markdownLayoutManager.hasThematicBreaks = document.hasThematicBreaks
        markdownTextStorage.setAttributedString(document.attributedString)
    }


    func codeBlockFrames() -> [(codeBlock: MarkdownCodeBlock, frame: NSRect)] {
        markdownLayoutManager.codeBlockFrames(in: markdownTextContainer)
    }

}

final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    private enum Layout {
        static let cornerRadius: CGFloat = 12
        static let verticalPadding: CGFloat = 16
        static let codeBlockHorizontalPadding: CGFloat = 10
        static let quoteIndentStep: CGFloat = 16
        static let quoteLineWidth: CGFloat = 3
        static let quoteLineInset: CGFloat = 6
        static let quoteVerticalInset: CGFloat = 2
    }

    var codeBlocks: [MarkdownCodeBlock] = []
    var codeBlockBackgroundColor: NSColor = .quaternarySystemFill
    var quoteBlocks: [MarkdownQuoteBlock] = []
    var quoteLineColor: NSColor = .tertiaryLabelColor
    var tableBlocks: [MarkdownTableBlock] = []
    var hasThematicBreaks = false

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        drawCodeBlockBackgrounds(forGlyphRange: glyphsToShow, at: origin)
        drawQuoteLines(forGlyphRange: glyphsToShow, at: origin)
        drawThematicBreaks(forGlyphRange: glyphsToShow, at: origin)
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        lineSpacingAfterGlyphAt glyphIndex: Int,
        withProposedLineFragmentRect rect: NSRect
    ) -> CGFloat {
        spacingAfterLineEndingGlyph(at: glyphIndex, keyPath: \.lineSpacing)
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        paragraphSpacingAfterGlyphAt glyphIndex: Int,
        withProposedLineFragmentRect rect: NSRect
    ) -> CGFloat {
        guard lineEndsParagraph(at: glyphIndex) else { return 0 }
        guard !lineEndsDocument(at: glyphIndex) else { return 0 }
        guard let paragraphStyle = paragraphStyle(at: glyphIndex) else { return 0 }
        return paragraphStyle.paragraphSpacing
    }

    private func drawCodeBlockBackgrounds(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard !codeBlocks.isEmpty else { return }

        let visibleCharacterRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let visibleCodeBlocks = codeBlocks.filter {
            NSIntersectionRange($0.range, visibleCharacterRange).length > 0
        }

        guard !visibleCodeBlocks.isEmpty else { return }

        for codeBlock in visibleCodeBlocks {
            let glyphRange = glyphRange(forCharacterRange: codeBlock.range, actualCharacterRange: nil)
            guard glyphRange.length > 0,
                  let blockRect = codeBlockRect(forGlyphRange: glyphRange, at: origin) else {
                continue
            }

            let path = NSBezierPath(
                roundedRect: blockRect,
                xRadius: Layout.cornerRadius,
                yRadius: Layout.cornerRadius
            )
            codeBlockBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    func codeBlockFrames(in textContainer: NSTextContainer) -> [(codeBlock: MarkdownCodeBlock, frame: NSRect)] {
        codeBlocks.compactMap { codeBlock in
            let glyphRange = glyphRange(forCharacterRange: codeBlock.range, actualCharacterRange: nil)
            guard glyphRange.length > 0,
                  let rect = codeBlockRect(forGlyphRange: glyphRange, at: .zero) else {
                return nil
            }
            return (codeBlock, rect)
        }
    }

    private func codeBlockRect(
        forGlyphRange glyphRange: NSRange,
        at origin: CGPoint
    ) -> NSRect? {
        var unionRect: NSRect?
        var maxUsedWidth: CGFloat = 0

        enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, usedRect, _, effectiveGlyphRange, _ in
            guard NSIntersectionRange(effectiveGlyphRange, glyphRange).length > 0 else { return }
            let adjustedRect = lineRect.offsetBy(dx: origin.x, dy: origin.y)
            unionRect = unionRect.map { $0.union(adjustedRect) } ?? adjustedRect
            maxUsedWidth = max(maxUsedWidth, usedRect.maxX)
        }

        guard let unionRect else { return nil }

        let contentWidth = maxUsedWidth + Layout.codeBlockHorizontalPadding
        return NSRect(
            x: unionRect.minX,
            y: unionRect.minY - Layout.verticalPadding / 2,
            width: contentWidth,
            height: unionRect.height + Layout.verticalPadding
        ).integral
    }

    private func drawQuoteLines(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard !quoteBlocks.isEmpty, let textContainer = textContainers.first else { return }

        let visibleCharacterRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let visibleQuoteBlocks = quoteBlocks.filter {
            NSIntersectionRange($0.range, visibleCharacterRange).length > 0
        }

        guard !visibleQuoteBlocks.isEmpty else { return }

        quoteLineColor.setFill()

        for quoteBlock in visibleQuoteBlocks {
            let glyphRange = glyphRange(forCharacterRange: quoteBlock.range, actualCharacterRange: nil)
            guard glyphRange.length > 0,
                  let blockRect = quoteBlockRect(forGlyphRange: glyphRange, in: textContainer, at: origin) else {
                continue
            }

            for level in 0..<quoteBlock.depth {
                let x = blockRect.minX + Layout.quoteLineInset + (CGFloat(level) * Layout.quoteIndentStep)
                let lineRect = NSRect(
                    x: x,
                    y: blockRect.minY + Layout.quoteVerticalInset,
                    width: Layout.quoteLineWidth,
                    height: max(0, blockRect.height - (Layout.quoteVerticalInset * 2))
                ).integral

                NSBezierPath(
                    roundedRect: lineRect,
                    xRadius: Layout.quoteLineWidth / 2,
                    yRadius: Layout.quoteLineWidth / 2
                ).fill()
            }
        }
    }

    private func quoteBlockRect(
        forGlyphRange glyphRange: NSRange,
        in textContainer: NSTextContainer,
        at origin: CGPoint
    ) -> NSRect? {
        var blockRect: NSRect?

        enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, effectiveGlyphRange, _ in
            guard NSIntersectionRange(effectiveGlyphRange, glyphRange).length > 0 else { return }
            let adjustedRect = lineRect.offsetBy(dx: origin.x, dy: origin.y)
            blockRect = blockRect.map { $0.union(adjustedRect) } ?? adjustedRect
        }

        guard var blockRect else { return nil }

        blockRect.origin.x += textContainer.lineFragmentPadding
        blockRect.size.width = max(0, blockRect.size.width - (textContainer.lineFragmentPadding * 2))
        return blockRect.integral
    }

    private func drawThematicBreaks(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard hasThematicBreaks, let textStorage, let textContainer = textContainers.first else { return }

        let visibleCharRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard visibleCharRange.length > 0 else { return }

        textStorage.enumerateAttribute(.markdownThematicBreak, in: visibleCharRange) { value, range, _ in
            guard value != nil else { return }

            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }

            self.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, _, _ in
                let adjustedRect = lineRect.offsetBy(dx: origin.x, dy: origin.y)
                let lineY = round(adjustedRect.midY)
                let lineX = adjustedRect.minX + textContainer.lineFragmentPadding
                let lineWidth = adjustedRect.width - (textContainer.lineFragmentPadding * 2)

                let linePath = NSBezierPath()
                linePath.move(to: NSPoint(x: lineX, y: lineY))
                linePath.line(to: NSPoint(x: lineX + lineWidth, y: lineY))
                linePath.lineWidth = 1
                NSColor.separatorColor.setStroke()
                linePath.stroke()
            }
        }
    }

    private func spacingAfterLineEndingGlyph(
        at glyphIndex: Int,
        keyPath: KeyPath<NSParagraphStyle, CGFloat>
    ) -> CGFloat {
        guard !lineEndsParagraph(at: glyphIndex) else { return 0 }
        guard let paragraphStyle = paragraphStyle(at: glyphIndex) else { return 0 }
        return paragraphStyle[keyPath: keyPath]
    }

    private func paragraphStyle(at glyphIndex: Int) -> NSParagraphStyle? {
        guard let textStorage else { return nil }
        let characterIndex = characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < textStorage.length else { return nil }
        return textStorage.attribute(.paragraphStyle, at: characterIndex, effectiveRange: nil) as? NSParagraphStyle
    }

    private func lineEndsParagraph(at glyphIndex: Int) -> Bool {
        guard let textStorage else { return true }
        let string = textStorage.string as NSString
        let characterIndex = characterIndexForGlyph(at: glyphIndex)

        guard characterIndex < string.length else { return true }

        if string.character(at: characterIndex).isMarkdownParagraphTerminator {
            return true
        }

        let nextCharacterIndex = characterIndex + 1
        guard nextCharacterIndex < string.length else { return true }
        return string.character(at: nextCharacterIndex).isMarkdownParagraphTerminator
    }

    private func lineEndsDocument(at glyphIndex: Int) -> Bool {
        guard let textStorage else { return true }
        let string = textStorage.string as NSString
        let characterIndex = characterIndexForGlyph(at: glyphIndex)

        guard characterIndex < string.length else { return true }

        if !string.character(at: characterIndex).isMarkdownParagraphTerminator {
            return characterIndex == string.length - 1
        }

        let nextCharacterIndex = characterIndex + 1
        return nextCharacterIndex >= string.length
    }
}

private extension unichar {
    var isMarkdownParagraphTerminator: Bool {
        guard let scalar = UnicodeScalar(self) else { return false }
        return CharacterSet.newlines.contains(scalar)
    }
}
