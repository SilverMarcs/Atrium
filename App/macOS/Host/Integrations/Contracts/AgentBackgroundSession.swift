import Foundation

/// A background shell session currently running under one of the host's agents.
nonisolated struct AgentBackgroundSession: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let provider: AgentProvider
    /// The provider's own thread or session identifier, without the provider prefix.
    let sessionID: String
    /// Agent-provided name or description, or a concise fallback derived from `command`.
    let title: String
    /// The shell command running in the background.
    let command: String
    /// Working directory where the session runs.
    let directory: String
    /// When the background session started, if known.
    let startedAt: Date?
    /// Local log file path when the provider writes live output to disk.
    let outputFilePath: String?
    /// Provider-specific item ID when live output comes from adapter notifications.
    let itemID: String?

    var taskID: String { "\(provider.rawValue):\(sessionID)" }

    /// A concise display name when an agent didn't supply a label of its own.
    static func fallbackTitle(forCommand command: String) -> String {
        let firstLine = command
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard !firstLine.isEmpty else { return "Background shell" }
        return firstLine.count > 64 ? String(firstLine.prefix(64)) + "…" : firstLine
    }

    static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        let lhsDate = lhs.startedAt ?? .distantPast
        let rhsDate = rhs.startedAt ?? .distantPast
        return lhsDate == rhsDate ? lhs.id < rhs.id : lhsDate > rhsDate
    }
}
