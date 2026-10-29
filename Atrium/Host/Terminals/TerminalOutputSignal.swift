import Synchronization

/// Only synchronized copied values cross from SwiftTerm's parse thread.
nonisolated final class TerminalOutputSignal: Sendable {
    private struct State: Sendable {
        var revision: UInt64 = 0
        var cursorVisible = true
    }
    private let state = Mutex(State())

    var revision: UInt64 { state.withLock { $0.revision } }
    var cursorVisible: Bool { state.withLock { $0.cursorVisible } }
    func recordOutput() { state.withLock { $0.revision &+= 1 } }
    func setCursorVisible(_ visible: Bool) { state.withLock { $0.cursorVisible = visible } }
}
