import AppKit
import SwiftTerm

/// Attaches a retained process view while SwiftUI replaces its host.
final class TerminalHostView: NSView {
    private final class WeakHost {
        weak var value: TerminalHostView?

        init(_ value: TerminalHostView) {
            self.value = value
        }
    }

    var acceptsInputFocus = true {
        didSet {
            guard acceptsInputFocus, !oldValue, let terminalView, terminalView.superview === self, let window else { return }
            window.makeFirstResponder(terminalView)
        }
    }

    private static var owners: [ObjectIdentifier: WeakHost] = [:]
    private weak var terminalView: TerminalView?
    private var rendering: TerminalRendering?

    func host(_ terminalView: TerminalView) {
        let terminalChanged = self.terminalView !== terminalView
        if terminalChanged {
            releaseCurrentTerminalView()
            self.terminalView = terminalView
            rendering = TerminalRendering(terminal: terminalView)
        }

        terminalView.translatesAutoresizingMaskIntoConstraints = true
        terminalView.autoresizingMask = []
        if terminalChanged {
            claimTerminalViewIfVisible()
        } else {
            reclaimTerminalViewIfOwned()
        }
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard window != nil else {
            releaseOwnership()
            detachTerminalView()
            return
        }

        claimTerminalViewIfVisible()
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.reclaimTerminalViewIfOwned()
        }
    }

    override func layout() {
        super.layout()
        reclaimTerminalViewIfOwned()
    }

    private func claimTerminalViewIfVisible() {
        guard window != nil, let terminalView else { return }

        let identifier = ObjectIdentifier(terminalView)
        Self.owners[identifier] = WeakHost(self)
        attach(terminalView)
    }

    private func reclaimTerminalViewIfOwned() {
        guard window != nil, let terminalView else { return }

        let identifier = ObjectIdentifier(terminalView)
        if let owner = Self.owners[identifier]?.value, owner !== self {
            return
        }
        Self.owners[identifier] = WeakHost(self)
        attach(terminalView)
    }

    private func attach(_ terminalView: TerminalView) {
        for subview in subviews where subview !== terminalView {
            subview.removeFromSuperview()
        }

        if terminalView.superview !== self {
            terminalView.removeFromSuperview()
            addSubview(terminalView)
            // Focus only when attaching a terminal. Model and layout updates
            // must leave keyboard focus in the editor or inspector alone.
            Task { @MainActor [weak self, weak terminalView] in
                guard let self, let terminalView,
                      self.acceptsInputFocus,
                      terminalView.superview === self,
                      let window = self.window else { return }
                window.makeFirstResponder(terminalView)
            }
        }
        // Padding belongs to the host rather than the engine's grid or renderer.
        let frame = bounds.insetBy(dx: min(6, bounds.width / 2), dy: min(6, bounds.height / 2))
        if terminalView.frame != frame {
            terminalView.frame = frame
        }
        rendering?.setVisible(true)
    }

    func releaseCurrentTerminalView() {
        releaseOwnership()
        detachTerminalView()
        self.terminalView = nil
        rendering = nil
    }

    private func detachTerminalView() {
        guard let terminalView else { return }
        if terminalView.superview === self {
            terminalView.removeFromSuperview()
        }
        // A retiring host must not release a renderer another window adopted.
        guard terminalView.window == nil else { return }
        rendering?.setVisible(false)
    }

    private func releaseOwnership() {
        guard let terminalView else { return }
        let identifier = ObjectIdentifier(terminalView)
        if Self.owners[identifier]?.value === self {
            Self.owners.removeValue(forKey: identifier)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            releaseOwnership()
        }
    }
}
