/// Optional actions and their effects are advertised by adapters, never inferred from identity.
struct AgentCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let markUnread = Self(rawValue: 1 << 0)
    static let deleteThread = Self(rawValue: 1 << 1)
    static let deleteDescendants = Self(rawValue: 1 << 2)
    static let renameThread = Self(rawValue: 1 << 3)
}
