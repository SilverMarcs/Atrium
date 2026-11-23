/// Optional actions and their effects are advertised by adapters, never inferred from identity.
struct AgentCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let deleteDescendants = Self(rawValue: 1 << 2)
    /// Side chats take images with their prompts.
    static let sideChatImages = Self(rawValue: 1 << 11)
}
