import Foundation

/// Who started a session for work they handed it, when that wasn't the user.
/// Apps list such sessions under whoever started them instead of on their own.
public nonisolated enum WireTaskOrigin: Codable, Sendable, Hashable {
    /// One of the subagents a session's agent runs itself, by that session's
    /// task ID. It can be read but not prompted: its agent talks to it.
    case subagent(String)
    /// Started by ChatGPT, which has no session of its own to list it under.
    case chatGPT
    /// A side chat about a session's conversation, by that session's task ID:
    /// the provider's own, which sees the conversation without changing it.
    /// It lasts until a new one replaces it or its provider ends it.
    case sideChat(String)

    /// The session a subagent works for or a side chat asks about.
    public var parentID: String? {
        switch self {
        case .subagent(let id), .sideChat(let id): id
        case .chatGPT: nil
        }
    }
}

public nonisolated extension WireTask {
    var isSubagent: Bool {
        if case .subagent = origin { true } else { false }
    }

    var isSideChat: Bool {
        if case .sideChat = origin { true } else { false }
    }
}
