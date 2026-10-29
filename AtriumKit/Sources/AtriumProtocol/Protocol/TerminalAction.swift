import Foundation

public nonisolated enum TerminalAction: Codable, Sendable {
    /// Input targets a particular process, so reconnects never type into a replacement.
    case input(terminalID: UUID, data: Data)
    case acknowledge(terminalID: UUID, sequence: UInt64)
    /// An explicit Resume Task action, separate from following an exited screen.
    case resume
}
