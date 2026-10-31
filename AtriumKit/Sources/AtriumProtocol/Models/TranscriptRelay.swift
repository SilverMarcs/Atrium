import Foundation

/// A user turn another agent wrote: a task ChatGPT handed this session, a
/// subagent's instructions from its agent, or the agent's own subagents
/// reporting back. Agents only take input as user turns, so all arrive as
/// one; apps show none as typed by the user.
public nonisolated struct TranscriptRelay: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// Work for this session, from ChatGPT through Atrium or from the agent
        /// running it as a subagent. Its text blocks hold only the request.
        case task
        /// Subagents reporting back, which fold into the reply as steps naming them.
        case results
    }

    /// An agent the message is from.
    public struct Sender: Codable, Sendable, Hashable {
        /// Such as `Claude · Fix the failing tests`.
        public var name: String
        /// The provider session it runs in, when the message says, so the host
        /// can name it as Atrium lists that session.
        public var sessionID: String?

        public init(name: String, sessionID: String? = nil) {
            self.name = name
            self.sessionID = sessionID
        }
    }

    public var kind: Kind
    /// A task's requester, or each agent reporting back.
    public var senders: [Sender]
    /// The Atrium task it hands this session, for a task from ChatGPT.
    public var taskID: String?

    public init(kind: Kind, senders: [Sender], taskID: String? = nil) {
        self.kind = kind
        self.senders = senders
        self.taskID = taskID
    }
}

public nonisolated extension [TranscriptMessage] {
    /// The conversation as its user follows it: subagents' reports fold into
    /// the reply they arrived during, as steps naming who reported back, so the
    /// only prompts left are the user's own and requests from other agents.
    func foldingReports() -> [TranscriptMessage] {
        var folded: [TranscriptMessage] = []
        for var message in self {
            if message.role == .user, let relay = message.relay, relay.kind == .results {
                message = TranscriptMessage(id: message.id, role: .assistant,
                                            blocks: relay.senders.enumerated().map { .report($1, id: "\(message.id).\($0)") })
            }
            // Replies the reports split continue as one.
            if message.role == .assistant, folded.last?.role == .assistant {
                folded[folded.count - 1].blocks += message.blocks
            } else {
                folded.append(message)
            }
        }
        return folded
    }
}
