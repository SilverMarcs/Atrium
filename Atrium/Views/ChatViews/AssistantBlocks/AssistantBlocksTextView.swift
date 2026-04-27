import AppKit

final class AssistantBlocksTextView: NSTextView {
    let blocksTextStorage = NSTextStorage()
    let blocksLayoutManager = MarkdownLayoutManager()
    let blocksTextContainer = NSTextContainer()

    var onToolCallClick: ((Int, NSRect) -> Void)?

    init() {
        blocksLayoutManager.delegate = blocksLayoutManager
        blocksLayoutManager.addTextContainer(blocksTextContainer)
        blocksTextStorage.addLayoutManager(blocksLayoutManager)
        super.init(frame: .zero, textContainer: blocksTextContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        markdownAncestorMenu(from: self)
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: localPoint.x - origin.x, y: localPoint.y - origin.y)
        let container = blocksTextContainer

        guard blocksLayoutManager.numberOfGlyphs > 0 else {
            super.mouseDown(with: event)
            return
        }
        let glyphIndex = blocksLayoutManager.glyphIndex(for: containerPoint, in: container)
        guard glyphIndex < blocksLayoutManager.numberOfGlyphs else {
            super.mouseDown(with: event)
            return
        }

        let charIndex = blocksLayoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < blocksTextStorage.length else {
            super.mouseDown(with: event)
            return
        }

        var rangeOfAttribute = NSRange()
        let groupID = blocksTextStorage.attribute(
            .assistantToolCallGroupID,
            at: charIndex,
            longestEffectiveRange: &rangeOfAttribute,
            in: NSRange(location: 0, length: blocksTextStorage.length)
        ) as? Int

        if let groupID {
            let glyphRange = blocksLayoutManager.glyphRange(forCharacterRange: rangeOfAttribute, actualCharacterRange: nil)
            let boundingRect = blocksLayoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            if boundingRect.contains(containerPoint) {
                let rectInTextView = boundingRect.offsetBy(dx: origin.x, dy: origin.y)
                onToolCallClick?(groupID, rectInTextView)
                return
            }
        }

        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()

        guard blocksTextStorage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: blocksTextStorage.length)
        blocksTextStorage.enumerateAttribute(.assistantToolCallGroupID, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = blocksLayoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = blocksLayoutManager.boundingRect(forGlyphRange: glyphRange, in: blocksTextContainer)
            let converted = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            addCursorRect(converted, cursor: .pointingHand)
        }
    }
}
