import Foundation

/// A saved command from a project on the host, and its latest run.
public nonisolated struct WireCommand: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    /// Nil for a command with nothing saved to run yet.
    public var script: String?
    public var isRunning: Bool
    public var isDefault: Bool
    /// The folder the latest run started in: the project folder, or the same
    /// folder in a linked worktree.
    public var directory: String?
    /// How the latest run ended, once it has.
    public var exitCode: Int32?

    public init(id: UUID, title: String, script: String? = nil, isRunning: Bool, isDefault: Bool,
                directory: String? = nil, exitCode: Int32? = nil) {
        self.id = id
        self.title = title
        self.script = script
        self.isRunning = isRunning
        self.isDefault = isDefault
        self.directory = directory
        self.exitCode = exitCode
    }

    public var canRun: Bool { !(script?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
}

/// A key a client can press in a running command, beyond typing a reply.
public nonisolated enum CommandKey: String, Codable, Sendable, CaseIterable {
    /// Control-C, which interrupts what's running.
    case interrupt
    /// Control-D, which ends what's typed into a program reading its input.
    case endOfInput
    case escape
    case tab
    case up
    case down
    case left
    case right
    case enter
}
