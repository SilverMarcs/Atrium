import Foundation

/// Who started a session for work they handed it, when that wasn't the user.
/// Apps list such sessions under whoever started them instead of on their own.
public nonisolated enum WireTaskOrigin: Codable, Sendable, Hashable {
    /// One of the subagents a session's agent runs itself, by that session's
    /// task ID. It can be read but not prompted: its agent talks to it.
    case subagent(String)
    /// Started by ChatGPT, which has no session of its own to list it under.
    case chatGPT

    /// The session this one works for, if it's a subagent.
    public var parentID: String? {
        if case .subagent(let id) = self { id } else { nil }
    }
}

public nonisolated extension WireTask {
    var isSubagent: Bool {
        if case .subagent = origin { true } else { false }
    }
}
