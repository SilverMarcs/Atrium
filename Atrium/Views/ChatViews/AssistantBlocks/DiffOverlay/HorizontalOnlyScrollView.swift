import AppKit

/// Scroll view that only handles horizontal scrolling itself — vertical scroll wheel
/// events are forwarded up the responder chain so the enclosing list scrolls instead.
final class HorizontalOnlyScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
