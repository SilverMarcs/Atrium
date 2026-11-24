import AppKit

/// Holds a chat's web view wherever it shows: the inspector, its own window,
/// or the hidden window it waits in. When a showing view goes away, the page
/// goes back to its hidden window, so the agent can keep using it.
final class BrowserHostView: NSView {
    private weak var browser: AgentBrowser?

    override var isFlipped: Bool { true }

    func show(_ browser: AgentBrowser) {
        self.browser = browser
        if browser.webView.superview !== self {
            subviews.forEach { $0.removeFromSuperview() }
            addSubview(browser.webView)
        }
        needsLayout = true
        browser.layOut(in: bounds)
    }

    /// SwiftUI sizes the view after it's shown, so the page follows each new size.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard let browser, browser.webView.superview === self else { return }
        browser.layOut(in: bounds)
    }

    override func layout() {
        super.layout()
        guard let browser, browser.webView.superview === self else { return }
        browser.layOut(in: bounds)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil, let browser, browser.webView.superview === self, self !== browser.parking.contentView else { return }
        browser.park()
    }
}
