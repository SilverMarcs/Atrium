import Foundation

/// A user turn another agent wrote: a task delegated to this session, a
/// subagent's instructions from its agent, or reports from agents it handed work
/// to, whether sessions Atrium delegated to or the agent's own subagents. Agents
/// only take input as user turns, so all arrive as one; apps show none as typed
/// by the user.
public nonisolated struct TranscriptRelay: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// Work for this session, delegated through Atrium or from the agent
        /// running it as a subagent. Its text blocks hold only the request.
        case task
        /// Agents reporting back or asking, which fold into the reply as steps naming them.
        case results
    }

    /// An agent the message is from.
    public struct Sender: Codable, Sendable, Hashable {
        /// Such as `Claude · Fix the failing tests`.
        public var name: String
        /// Whether it asks this session a question rather than reporting back.
        public var asksQuestion: Bool
        /// The provider session it runs in, when the message says, so the host
        /// can name it as Atrium lists that session.
        public var sessionID: String?

        public init(name: String, asksQuestion: Bool = false, sessionID: String? = nil) {
            self.name = name
            self.asksQuestion = asksQuestion
            self.sessionID = sessionID
        }
    }

    public var kind: Kind
    /// A task's requester, or each agent reporting back or asking.
    public var senders: [Sender]
    /// The Atrium tasks whose results it carries, or the task it delegates.
    /// Empty when no Atrium task is involved, as for a subagent's instructions
    /// from its agent or its reports.
    public var taskIDs: [String]
    /// The Atrium tasks whose questions it passes on, which are still under way.
    public var questionTaskIDs: [String]

    public init(kind: Kind, senders: [Sender], taskIDs: [String] = [], questionTaskIDs: [String] = []) {
        self.kind = kind
        self.senders = senders
        self.taskIDs = taskIDs
        self.questionTaskIDs = questionTaskIDs
    }
}

public nonisolated extension [TranscriptMessage] {
    /// The conversation as its user follows it: reports from other agents fold
    /// into the reply they arrived during, as steps naming who reported back or
    /// asked, so the only prompts left are the user's own and requests from other agents.
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
