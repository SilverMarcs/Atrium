import AppKit

struct SharedDiffLine {
    let content: String
    let kind: GitDiffLineKind?
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

struct SharedDiffTextLayout {
    let gutterWidth: CGFloat
    let verticalPadding: CGFloat
    let wrapsLines: Bool
    let fontSize: CGFloat
    let lineNumberFontSize: CGFloat

    static func hunk(fontSize: CGFloat) -> SharedDiffTextLayout {
        SharedDiffTextLayout(
            gutterWidth: 36,
            verticalPadding: 0,
            wrapsLines: true,
            fontSize: fontSize,
            lineNumberFontSize: fontSize - 1
        )
    }

    static func popover(wrapsLines: Bool) -> SharedDiffTextLayout {
        SharedDiffTextLayout(
            gutterWidth: 36,
            verticalPadding: 0,
            wrapsLines: wrapsLines,
            fontSize: 12,
            lineNumberFontSize: 11
        )
    }
}

final class SharedDiffTextView: NSTextView {
    private var lineData: [SharedDiffLine] = []
    private var layoutStyle: SharedDiffTextLayout = .popover(wrapsLines: false)

    func configure(lines: [SharedDiffLine], fileExtension: String, layout: SharedDiffTextLayout, width: CGFloat) {
        lineData = lines
        layoutStyle = layout

        appearance = NSApp.effectiveAppearance
        isEditable = false
        isSelectable = true
        isRichText = false
        font = NSFont.monospacedSystemFont(ofSize: layout.fontSize, weight: .regular)
        backgroundColor = .clear
        drawsBackground = false
        textColor = .labelColor
        textContainerInset = NSSize(width: layout.gutterWidth, height: layout.verticalPadding)
        isVerticallyResizable = true
        isHorizontallyResizable = !layout.wrapsLines
        autoresizingMask = layout.wrapsLines ? [.width] : []

        if layout.wrapsLines {
            textContainer?.widthTracksTextView = true
        } else {
            textContainer?.widthTracksTextView = false
            textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            minSize = NSSize(width: width, height: 0)
        }

        let source = lines.map(\.content).joined(separator: "\n")
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let attributed = NSMutableAttributedString(
            attributedString: SyntaxHighlighter.highlight(
                source,
                fileExtension: fileExtension,
                fontSize: layout.fontSize,
                isDark: isDark
            )
        )
        textStorage?.setAttributedString(attributed)
        applyInlineHighlights(lines: lines)

        let text = source as NSString
        layoutManager?.ensureLayout(forCharacterRange: NSRange(location: 0, length: text.length))
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            appearance = window.effectiveAppearance
            needsDisplay = true
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard let layoutManager, let textContainer else { return }

        let text = string as NSString
        let containerOrigin = textContainerOrigin
        let gutterWidth = layoutStyle.gutterWidth

        guard text.length > 0 else { return }

        let fullRange = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: fullRange, actualGlyphRange: nil)

        let lineNumberAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: layoutStyle.lineNumberFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        text.enumerateSubstrings(in: charRange, options: [.byLines, .substringNotRequired]) { _, substringRange, enclosingRange, _ in
            let lineIndex = self.lineIndex(forCharacterIndex: substringRange.location)
            guard lineIndex < self.lineData.count else { return }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: enclosingRange, actualCharacterRange: nil)
            var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            lineRect.origin.y += containerOrigin.y

            let data = self.lineData[lineIndex]
            if let kind = data.kind {
                let backgroundColor = kind.color.withAlphaComponent(0.12)
                var backgroundRect = lineRect
                backgroundRect.origin.x = gutterWidth
                backgroundRect.size.width = self.bounds.width - gutterWidth
                backgroundColor.setFill()
                backgroundRect.fill()
            }

            let lineNumber = data.newLineNumber ?? data.oldLineNumber
            if let lineNumber {
                let string = "\(lineNumber)" as NSString
                let size = string.size(withAttributes: lineNumberAttributes)
                string.draw(
                    at: NSPoint(x: gutterWidth - size.width - 6, y: lineRect.minY),
                    withAttributes: lineNumberAttributes
                )
            }
        }
    }

    private func applyInlineHighlights(lines: [SharedDiffLine]) {
        guard let textStorage else { return }

        var lineOffsets: [Int] = []
        var offset = 0
        for line in lines {
            lineOffsets.append(offset)
            offset += (line.content as NSString).length + 1
        }

        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removed else {
                index += 1
                continue
            }

            let removedStart = index
            while index < lines.count && lines[index].kind == .removed {
                index += 1
            }
            let removedEnd = index

            guard index < lines.count && lines[index].kind == .added else { continue }
            let addedStart = index
            while index < lines.count && lines[index].kind == .added {
                index += 1
            }
            let addedEnd = index

            let pairCount = min(removedEnd - removedStart, addedEnd - addedStart)
            for pairIndex in 0..<pairCount {
                let removedIndex = removedStart + pairIndex
                let addedIndex = addedStart + pairIndex
                let (oldRange, newRange) = Self.inlineDiffRanges(
                    old: lines[removedIndex].content,
                    new: lines[addedIndex].content
                )

                if let oldRange {
                    let range = NSRange(
                        location: lineOffsets[removedIndex] + oldRange.lowerBound,
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
                        location: lineOffsets[addedIndex] + newRange.lowerBound,
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
        let oldCharacters: [unichar] = Array(old.utf16)
        let newCharacters: [unichar] = Array(new.utf16)

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

    private func lineIndex(forCharacterIndex index: Int) -> Int {
        let text = string as NSString
        var lineIndex = 0
        var i = 0
        while i < index && i < text.length {
            if text.character(at: i) == 0x0A {
                lineIndex += 1
            }
            i += 1
        }
        return lineIndex
    }
}
