import Foundation

/// A prompt Atrium wrote into a session for another agent: a task delegated to
/// this session, or the results of tasks it delegated. Apps show it as relayed
/// rather than typed by the user; its text blocks hold only what was relayed.
public nonisolated struct TranscriptRelay: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case task
        case results
    }

    public var kind: Kind
    /// The agent the message is from, such as `Claude · Fix the failing tests`.
    public var sender: String
    /// The tasks whose results it carries, or the task it delegates.
    public var taskIDs: [String]
    /// The tasks whose questions it passes on, which are still under way.
    public var questionTaskIDs: [String]

    public init(kind: Kind, sender: String, taskIDs: [String], questionTaskIDs: [String] = []) {
        self.kind = kind
        self.sender = sender
        self.taskIDs = taskIDs
        self.questionTaskIDs = questionTaskIDs
    }
}
