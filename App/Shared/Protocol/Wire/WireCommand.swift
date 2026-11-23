import Foundation

/// A saved command from a project on the host, and its latest run.
nonisolated struct WireCommand: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var title: String
    /// Nil for a command with nothing saved to run yet.
    var script: String?
    var isRunning: Bool
    var isDefault: Bool
    /// The folder the latest run started in: the project folder, or the same
    /// folder in a linked worktree.
    var directory: String?
    /// How the latest run ended, once it has.
    var exitCode: Int32?

    init(id: UUID, title: String, script: String? = nil, isRunning: Bool, isDefault: Bool,
                directory: String? = nil, exitCode: Int32? = nil) {
        self.id = id
        self.title = title
        self.script = script
        self.isRunning = isRunning
        self.isDefault = isDefault
        self.directory = directory
        self.exitCode = exitCode
    }

    var canRun: Bool { !(script?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
}

/// A key a client can press in a running command, beyond typing a reply.
nonisolated enum CommandKey: String, Codable, Sendable, CaseIterable {
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
