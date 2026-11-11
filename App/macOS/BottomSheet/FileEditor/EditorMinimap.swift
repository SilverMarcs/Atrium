import AppKit

final class EditorMinimap: NSView {
    var totalLines: Int = 1 { didSet { needsDisplay = true } }
    var width: CGFloat = 20
    var onScrollToFraction: ((CGFloat) -> Void)?

    // Consolidated marker ranges for efficient drawing
    private(set) var markerRanges: [(startLine: Int, endLine: Int, color: NSColor)] = []

    // Viewport fraction (0–1)
    var viewportStart: CGFloat = 0
    var viewportEnd: CGFloat = 0.1

    override var isFlipped: Bool { true }

    func setMarkers(_ lineColors: [Int: NSColor]) {
        let sorted = lineColors.sorted { $0.key < $1.key }
        var ranges: [(startLine: Int, endLine: Int, color: NSColor)] = []
        for (line, color) in sorted {
            if let last = ranges.last, last.endLine == line - 1, last.color == color {
                ranges[ranges.count - 1] = (last.startLine, line, color)
            } else {
                ranges.append((line, line, color))
            }
        }
        markerRanges = ranges
        needsDisplay = true
    }

    func updateViewport(from scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView else { return }
        let totalHeight = documentView.frame.height
        guard totalHeight > 0 else { return }
        let visible = scrollView.contentView.bounds
        viewportStart = visible.origin.y / totalHeight
        viewportEnd = min((visible.origin.y + visible.height) / totalHeight, 1)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = bounds.height
        guard totalLines > 0, height > 0 else { return }

        // Markers
        let pixelsPerLine = height / CGFloat(totalLines)
        let markerHeight = max(pixelsPerLine, 1.5)

        for (startLine, endLine, color) in markerRanges {
            let y = CGFloat(startLine - 1) * pixelsPerLine
            let h = CGFloat(endLine - startLine + 1) * pixelsPerLine
            color.withAlphaComponent(0.5).setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: max(h, markerHeight)).fill()
        }

        // Viewport indicator
        let vpY = viewportStart * height
        let vpH = max((viewportEnd - viewportStart) * height, 4)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSRect(x: 0, y: vpY, width: bounds.width, height: vpH).fill()

        NSColor.labelColor.withAlphaComponent(0.1).setStroke()
        let border = NSBezierPath()
        border.move(to: NSPoint(x: 0, y: vpY))
        border.line(to: NSPoint(x: bounds.width, y: vpY))
        border.move(to: NSPoint(x: 0, y: vpY + vpH))
        border.line(to: NSPoint(x: bounds.width, y: vpY + vpH))
        border.lineWidth = 0.5
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) { handleClick(event) }
    override func mouseDragged(with event: NSEvent) { handleClick(event) }

    private func handleClick(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let fraction = max(0, min(point.y / bounds.height, 1))
        onScrollToFraction?(fraction)
    }
}
