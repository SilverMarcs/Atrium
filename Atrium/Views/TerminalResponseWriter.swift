import SwiftTerm

/// Exposes only LocalProcess's synchronized PTY write operation across threads.
/// SwiftTerm parses on its IO thread; routing replies through AppKit can exceed
/// a program's startup probe deadline while the window is being built.
nonisolated final class TerminalResponseWriter: @unchecked Sendable {
    private let process: LocalProcess

    @MainActor
    init(process: LocalProcess) {
        self.process = process
    }

    func send(_ data: ArraySlice<UInt8>) {
        process.send(data: data)
    }
}
