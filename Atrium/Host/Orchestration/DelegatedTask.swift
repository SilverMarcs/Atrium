import AtriumProtocol
import Foundation

/// Work one caller handed to a session: a single turn of that session, from
/// the prompt Atrium sends it to the turn's end, and whether its result has
/// reached the caller.
///
/// It's recorded before Atrium starts anything, so a turn that ends at once
/// still finds it, and saved with every change, so it survives a restart.
nonisolated struct DelegatedTask: Codable, Sendable, Identifiable {
    enum State: String, Codable, Sendable {
        /// Recorded; the session is being created or the prompt sent.
        case starting
        /// The prompt reached the agent; waiting for its turn to begin.
        case sent
        /// The agent is working on it, or waiting on work it started for it.
        case running
        /// The agent is waiting for an answer or an approval from the user.
        case needsInput = "needs_input"
        case completed
        case failed
        case interrupted

        var isFinished: Bool { self == .completed || self == .failed || self == .interrupted }
    }

    enum Delivery: String, Codable, Sendable {
        /// The caller can't be woken, as ChatGPT can't; it asks with `task_status`.
        case none
        /// Waiting for the task to finish, or for the caller to be free.
        case pending
        /// The prompt carrying the result is being sent.
        case delivering
        case delivered
        /// The caller read the result itself before it was delivered.
        case acknowledged
        /// Not delivered, for the reason in `deliveryNote`.
        case withheld
    }

    let id: String
    let requester: Requester
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
    var delivery: Delivery
    var deliveryNote: String?
    var deliveryAttempts = 0
    /// Questions from the session already passed on to the requester, by interaction ID.
    var relayedQuestionIDs: Set<String> = []
    /// The chain of delegations this task belongs to, which shares one budget.
    let chainID: UUID
    /// 1 for a task a session started on its own; one more for each task
    /// started by an agent that was itself working on a delegated task.
    let depth: Int
    /// A caller-chosen key that makes repeating the request return this task.
    let requestKey: String?

    /// Who asked for the work and receives its result.
    enum Requester: Codable, Sendable, Hashable {
        case session(taskID: String)
        case remote

        init(_ caller: ToolCaller) {
            switch caller {
            case .session(let taskID): self = .session(taskID: taskID)
            // A starting session can't call tools, so it never asks for work.
            case .remote, .startingSession: self = .remote
            }
        }

        var sessionID: String? {
            if case .session(let taskID) = self { taskID } else { nil }
        }
    }
}
