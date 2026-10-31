import AtriumProtocol
import Foundation

/// Work ChatGPT handed to a session: a single turn of that session, from the
/// prompt Atrium sends it to the turn's end.
///
/// It's recorded before Atrium starts anything, so a turn that ends at once
/// still finds it, and saved with every change, so it survives a restart.
nonisolated struct DelegatedTask: Codable, Sendable, Identifiable {
    enum State: String, Codable, Sendable {
        /// Recorded; the session is being created or the prompt sent.
        case starting
        /// The prompt reached the agent; waiting for its turn to begin.
        case sent
        /// The agent is working on it, or waiting on its subagents.
        case running
        /// The agent is waiting for an answer or an approval from the user.
        case needsInput = "needs_input"
        case completed
        case failed
        case interrupted

        var isFinished: Bool { self == .completed || self == .failed || self == .interrupted }
    }

    let id: String
    /// The session doing the work, once it exists.
    var sessionID: String?
    let provider: AgentProvider
    /// Whether Atrium started the session for this task, rather than continuing one.
    let startsSession: Bool
    let title: String?
    let prompt: String
    let createdAt: Date
    var updatedAt: Date
    var state: State
    /// The agent's final reply, or why the task failed.
    var result: String?
    /// A caller-chosen key that makes repeating the request return this task.
    let requestKey: String?
}
