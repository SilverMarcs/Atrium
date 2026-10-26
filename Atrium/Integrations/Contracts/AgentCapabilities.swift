/// Optional actions and their effects are advertised by adapters, never inferred from identity.
struct AgentCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let markRead = Self(rawValue: 1 << 5)
    static let markUnread = Self(rawValue: 1 << 0)
    static let deleteThread = Self(rawValue: 1 << 1)
    static let deleteDescendants = Self(rawValue: 1 << 2)
    static let forkThread = Self(rawValue: 1 << 4)
    static let renameThread = Self(rawValue: 1 << 3)
    /// The adapter delivers prompts and interrupts itself, without a terminal.
    static let prompt = Self(rawValue: 1 << 6)
    /// Prompts are typed into the thread's attached terminal instead.
    static let terminalPrompt = Self(rawValue: 1 << 7)
    /// The model, reasoning effort and fast mode can be changed, through the
    /// adapter with `.prompt` or by typing commands with `.terminalPrompt`.
    static let selectModel = Self(rawValue: 1 << 8)
}
