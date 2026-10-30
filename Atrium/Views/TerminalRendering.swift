import AppKit
import SwiftTerm

/// Both local and remote terminals keep their contents independently of the
/// graphics resources used to display them.
@MainActor
final class TerminalRendering {
    private let terminal: TerminalView
    private var releaseTask: Task<Void, Never>?
    private var isClosed = false

    init(terminal: TerminalView) {
        self.terminal = terminal
    }

    func setVisible(_ isVisible: Bool) {
        guard !isClosed else { return }
        releaseTask?.cancel()
        releaseTask = nil
        if isVisible {
            // CoreGraphics remains available if Metal cannot be initialized.
            try? terminal.setUseMetal(true)
        } else {
            release(permanently: false)
        }
    }

    /// Remote canvases are discarded when their subscription ends. Local
    /// process views stay alive so they can still parse output and accept input.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        releaseTask?.cancel()
        release(permanently: true)
    }

    private func release(permanently: Bool) {
        guard !Self.release(terminal, permanently: permanently) else { return }
        // SwiftTerm keeps the renderer when committed GPU work has not finished.
        // Retry without holding up navigation, and abandon a temporary release
        // if another host has already put this terminal back in a window.
        releaseTask = Task { [terminal] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, permanently || terminal.window == nil else { return }
                if Self.release(terminal, permanently: permanently) { return }
            }
        }
    }

    private static func release(_ terminal: TerminalView, permanently: Bool) -> Bool {
        if permanently { return terminal.updateUiClosed() }
        do {
            try terminal.setUseMetal(false)
            return true
        } catch {
            return false
        }
    }
}
