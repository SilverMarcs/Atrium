import Foundation

/// Task actions that are currently allowed. The Mac decides; the companion
/// receives the same set, so neither offers an action the other would reject.
public nonisolated struct TaskActions: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let settle = Self(rawValue: 1 << 0)
    public static let restore = Self(rawValue: 1 << 1)
    public static let snooze = Self(rawValue: 1 << 2)
    public static let unsnooze = Self(rawValue: 1 << 3)
    public static let fork = Self(rawValue: 1 << 4)
    public static let rename = Self(rawValue: 1 << 5)
    public static let markRead = Self(rawValue: 1 << 6)
    public static let markUnread = Self(rawValue: 1 << 7)
    public static let delete = Self(rawValue: 1 << 8)
    /// The agent can take a prompt right now.
    public static let prompt = Self(rawValue: 1 << 9)
    /// The agent is working and its turn can be stopped.
    public static let interrupt = Self(rawValue: 1 << 10)
    /// The agent's model, reasoning effort and fast mode can be changed right now.
    public static let selectModel = Self(rawValue: 1 << 11)

    /// Conversation history can be rewound while the agent is idle.
    public static let editMessage = Self(rawValue: 1 << 12)
    /// A side chat can start about the conversation so far.
    public static let sideChat = Self(rawValue: 1 << 13)
    /// Prompts can include images.
    public static let attachImages = Self(rawValue: 1 << 14)
}
