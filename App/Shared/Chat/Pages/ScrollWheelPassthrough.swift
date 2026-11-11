#if os(macOS)
import AppKit
import SwiftUI

/// WebKit keeps scroll-wheel events over a page even when the page has nothing
/// to scroll, which would stop the timeline scrolling under the pointer. While
/// enabled, this sends wheel events over its frame to the enclosing scroll view.
struct ScrollWheelPassthrough: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> PassthroughView { PassthroughView() }

    func updateNSView(_ view: PassthroughView, context: Context) {
        view.isEnabled = isEnabled
    }

    static func dismantleNSView(_ view: PassthroughView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class PassthroughView: NSView {
        var isEnabled = false
        private var monitor: Any?

        // Clicks and hovers still reach the page above it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.isEnabled, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      let scrollView = self.enclosingScrollView else { return event }
                scrollView.scrollWheel(with: event)
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
