import AppKit
import AtriumProtocol
import SwiftTerm

/// The host owns the grid. A smaller companion scrolls its viewport rather than
/// reflowing the host's TUI or repeatedly resizing the running process.
final class RemoteTerminalViewport: NSScrollView {
    let terminal = RemoteTerminalCanvas(frame: .zero)
    private var displayed: WireTerminalFrame?
    private var isDark: Bool?

    init() {
        super.init(frame: .zero)
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        documentView = terminal
        terminal.setCursorStyle(.steadyBlock)
        terminal.changeScrollback(WireTerminalFrame.scrollbackRows)
        let size = TerminalProcessRegistry.fontSize
        terminal.font = NSFont(descriptor: terminal.font.fontDescriptor, size: size) ?? terminal.font
        try? terminal.setUseMetal(true)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.window != nil else { return }
            self.window?.makeFirstResponder(self.terminal)
        }
    }

    func update(_ frame: WireTerminalFrame, isDark: Bool) {
        if self.isDark != isDark {
            self.isDark = isDark
            terminal.nativeForegroundColor = isDark ? NSColor(white: 0.90, alpha: 1) : .labelColor
            terminal.nativeBackgroundColor = .windowBackgroundColor
        }
        guard displayed != frame else { return }
        if displayed == nil || terminal.terminalDimensions.cols != frame.columns || terminal.terminalDimensions.rows != frame.rows {
            terminal.resize(cols: frame.columns, rows: frame.rows)
            terminal.setFrameSize(terminal.getOptimalFrameSize().size)
            displayed = nil
        }
        terminal.feed(text: frame.presentation(since: displayed))
        displayed = frame
    }
}
