import Foundation

/// Who started a session for work they handed it, when that wasn't the user.
/// Apps nest sessions with a parent under that parent.
nonisolated enum WireTaskOrigin: Codable, Sendable, Hashable {
    /// One of the subagents a session's agent runs itself, by that session's
    /// task ID. It can be read but not prompted: its agent talks to it.
    case subagent(String)
    /// Started by another session's agent with the host's session tools,
    /// by that session's task ID. It stops with that session.
    case session(String)
    /// Started by a paired agent, such as ChatGPT, by that device's name.
    /// It has no session to list it under.
    case device(String)
    /// A side chat about a session's conversation, by that session's task ID:
    /// the provider's own, which sees the conversation without changing it.
    /// It lasts until a new one replaces it or its provider ends it.
    case sideChat(String)

    /// The session a subagent or delegated session works for, or a side chat asks about.
    var parentID: String? {
        switch self {
        case .subagent(let id), .session(let id), .sideChat(let id): id
        case .device: nil
        }
    }

    /// The device that started the session, for one a paired agent started.
    var deviceName: String? {
        if case .device(let name) = self { name } else { nil }
    }
}

nonisolated extension WireTask {
    var isSubagent: Bool {
        if case .subagent = origin { true } else { false }
    }

    var isSideChat: Bool {
        if case .sideChat = origin { true } else { false }
    }
}
