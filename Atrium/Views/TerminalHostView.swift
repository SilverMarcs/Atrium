import AppKit

/// Keeps a retained command terminal attached to one visible SwiftUI host.
/// Hidden or outgoing hosts cannot reclaim it during view transitions.
@MainActor
final class TerminalHostView: NSView {
    private final class WeakHost {
        weak var value: TerminalHostView?

        init(_ value: TerminalHostView) {
            self.value = value
        }
    }

    private static var owners: [ObjectIdentifier: WeakHost] = [:]
    private weak var terminalView: NSView?

    func host(_ terminalView: NSView) {
        let terminalChanged = self.terminalView !== terminalView
        if terminalChanged {
            releaseCurrentTerminalView()
            self.terminalView = terminalView
        }

        terminalView.translatesAutoresizingMaskIntoConstraints = true
        terminalView.autoresizingMask = [.width, .height]
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

    private func attach(_ terminalView: NSView) {
        for subview in subviews where subview !== terminalView {
            subview.removeFromSuperview()
        }

        if terminalView.superview !== self {
            terminalView.removeFromSuperview()
            addSubview(terminalView)
        }
        terminalView.frame = bounds
    }

    private func releaseCurrentTerminalView() {
        guard let terminalView else { return }
        releaseOwnership()
        if terminalView.superview === self {
            terminalView.removeFromSuperview()
        }
        self.terminalView = nil
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
