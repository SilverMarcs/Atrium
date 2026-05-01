import SwiftUI
import AppKit

final class QuickPanelWindow: NSPanel {
    private var heightConstraint: NSLayoutConstraint?
    private weak var controller: QuickPanelController?
    private var currentHeight: QuickPanelHeight = .collapsed

    init(controller: QuickPanelController) {
        self.controller = controller
        let initialSize = NSSize(width: 650, height: QuickPanelHeight.collapsed.value)
        super.init(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.nonactivatingPanel, .closable, .fullSizeContentView, .titled],
            backing: .buffered,
            defer: false
        )

        identifier = NSUserInterfaceItemIdentifier("atriumQuickPanel")
        isFloatingPanel = true
        level = .floating
        collectionBehavior.insert(.fullScreenDisallowsTiling)
        titleVisibility = .hidden
        toolbar?.isVisible = false
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        backgroundColor = .clear

        let hosting = NSHostingView(
            rootView: QuickPanelView(
                controller: controller,
                onHeightChange: { [weak self] in self?.setHeight($0) },
                onDismiss: { [weak self] in self?.close() }
            )
            // Quick panel has no bottom editor; satisfy `MessageRow`'s
            // `@Environment(EditorPanel.self)` with an inert stub.
            .environment(EditorPanel())
            .ignoresSafeArea()
        )

        let glass = NSGlassEffectView()
        glass.autoresizingMask = [.width, .height]
        glass.contentView = hosting
        contentView = glass

        heightConstraint = glass.heightAnchor.constraint(equalToConstant: initialSize.height)
        heightConstraint?.isActive = true
        contentMinSize = NSSize(width: initialSize.width, height: QuickPanelHeight.collapsed.value)
        contentMaxSize = NSSize(width: initialSize.width, height: QuickPanelHeight.expanded.value)

        center()
    }

    func setHeight(_ state: QuickPanelHeight) {
        guard state != currentHeight else { return }
        currentHeight = state
        let height = state.value
        guard let screenFrame = screen?.visibleFrame else { return }
        let current = frame
        // Anchor to current top edge so the panel grows downward, matching LynkChat.
        let topY = current.origin.y + current.height
        let newY = max(screenFrame.minY, topY - height)
        let newFrame = NSRect(x: current.origin.x, y: newY, width: current.width, height: height)
        setFrame(newFrame, display: true)
        contentView?.setFrameSize(newFrame.size)
        heightConstraint?.constant = height
        contentMinSize.height = height
        contentMaxSize.height = max(QuickPanelHeight.expanded.value, height)
    }

    override func resignMain() {
        super.resignMain()
        close()
    }

    override func close() {
        controller?.didClose()
        super.close()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
