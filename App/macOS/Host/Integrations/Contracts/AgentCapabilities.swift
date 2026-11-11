/// Optional actions and their effects are advertised by adapters, never inferred from identity.
struct AgentCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let deleteThread = Self(rawValue: 1 << 1)
    static let deleteDescendants = Self(rawValue: 1 << 2)
    static let forkThread = Self(rawValue: 1 << 4)
    static let renameThread = Self(rawValue: 1 << 3)
    /// The model, reasoning effort and fast mode can be changed for a thread's next turns.
    static let selectModel = Self(rawValue: 1 << 8)
    static let editMessage = Self(rawValue: 1 << 9)
    /// Side chats can start about a thread's conversation, in the provider's own way.
    static let sideChat = Self(rawValue: 1 << 10)
    /// Side chats take images with their prompts.
    static let sideChatImages = Self(rawValue: 1 << 11)
}
