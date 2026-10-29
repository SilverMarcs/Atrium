import AppKit
import SwiftTerm
import Synchronization

/// Keeps terminal colors and the theme reported to programs in sync.
@MainActor
final class AppTerminalView: LocalProcessTerminalView {
    private var appliedIsDark: Bool?
    nonisolated private let responseWriter = Mutex<TerminalResponseWriter?>(nil)
    nonisolated private let remoteOutput = TerminalOutputSignal()

    nonisolated var outputRevision: UInt64 { remoteOutput.revision }
    nonisolated var isCursorVisible: Bool { remoteOutput.cursorVisible }

    /// Called after each chunk of process output is fed to the terminal.
    var onOutput: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
    }

    /// Install before launch: startup color probes must not wait for UI work.
    func prepareProcessResponses() {
        setProcessOutputHandler { [remoteOutput] in
            remoteOutput.recordOutput()
        }
        let writer = TerminalResponseWriter(process: process)
        responseWriter.withLock { $0 = writer }
    }

    nonisolated override func showCursor(source: SwiftTerm.Terminal) {
        remoteOutput.setCursorVisible(true)
        super.showCursor(source: source)
    }

    nonisolated override func hideCursor(source: SwiftTerm.Terminal) {
        remoteOutput.setCursorVisible(false)
        super.hideCursor(source: source)
    }

    nonisolated override func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {
        let writer = responseWriter.withLock { $0 }
        if let writer {
            writer.send(data)
        } else {
            super.send(source: source, data: data)
        }
    }

    /// Use the host's scheme even before this retained view belongs to a window.
    func applyAppearance(isDark: Bool) {
        guard appliedIsDark != isDark,
              let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua) else { return }
        appearance.performAsCurrentDrawingAppearance {
            let foreground = isDark ? NSColor(white: 0.90, alpha: 1) : .labelColor
            let background = NSColor.windowBackgroundColor
            nativeForegroundColor = foreground.usingColorSpace(.sRGB) ?? foreground
            nativeBackgroundColor = (background.usingColorSpace(.sRGB) ?? background).withAlphaComponent(0)
        }
        updateColorScheme(isDark ? .dark : .light)
        appliedIsDark = isDark
    }
}
