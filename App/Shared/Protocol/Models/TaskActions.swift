import Foundation

/// Task actions that are currently allowed. The Mac decides; the companion
/// receives the same set, so neither offers an action the other would reject.
nonisolated struct TaskActions: OptionSet, Codable, Sendable, Hashable {
    let rawValue: Int

    static let settle = Self(rawValue: 1 << 0)
    static let restore = Self(rawValue: 1 << 1)
    static let snooze = Self(rawValue: 1 << 2)
    static let unsnooze = Self(rawValue: 1 << 3)
    /// The chat can be forked, whole or before one of its prompts, into any provider the host has enabled.
    static let fork = Self(rawValue: 1 << 4)
    static let rename = Self(rawValue: 1 << 5)
    static let markRead = Self(rawValue: 1 << 6)
    static let markUnread = Self(rawValue: 1 << 7)
    static let delete = Self(rawValue: 1 << 8)
    /// The agent can take a prompt right now.
    static let prompt = Self(rawValue: 1 << 9)
    /// The agent is working and its turn can be stopped.
    static let interrupt = Self(rawValue: 1 << 10)
    /// The agent's model, reasoning effort, fast mode and permission mode can be changed right now.
    static let selectModel = Self(rawValue: 1 << 11)

    /// Conversation history can be rewound while the agent is idle.
    static let editMessage = Self(rawValue: 1 << 12)
    /// A side chat can start about the conversation so far.
    static let sideChat = Self(rawValue: 1 << 13)
    /// Prompts can include images.
    static let attachImages = Self(rawValue: 1 << 14)
    /// The conversation can open in a terminal on the host, attached to the same session.
    static let openTerminal = Self(rawValue: 1 << 15)
}
