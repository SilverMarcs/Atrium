import CoreGraphics

extension LivePreviewInput {
    /// A tap, or a swipe when the pointer moved, for a drag across the video
    /// shown in `rect`; nothing when it began outside the video.
    static func drag(from start: CGPoint, to end: CGPoint, in rect: CGRect) -> Self? {
        guard rect.width > 0, rect.height > 0, rect.contains(start) else { return nil }
        let from = PreviewPoint(start, in: rect)
        return hypot(end.x - start.x, end.y - start.y) < 8 ? .tap(from) : .swipe(from: from, to: PreviewPoint(end, in: rect))
    }
}

private extension PreviewPoint {
    init(_ point: CGPoint, in rect: CGRect) {
        self.init(
            x: min(1, max(0, (point.x - rect.minX) / rect.width)),
            y: min(1, max(0, (point.y - rect.minY) / rect.height))
        )
    }
}
