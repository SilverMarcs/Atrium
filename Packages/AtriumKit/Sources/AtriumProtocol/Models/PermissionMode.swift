/// How freely an agent acts without asking. Each provider maps these to its
/// own settings; a mode it can't use isn't offered.
public nonisolated enum PermissionMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Asks before edits and commands.
    case supervised
    /// Edits files without asking.
    case acceptEdits
    /// The provider's automatic review approves or blocks each action.
    case auto
    /// Never asks.
    case fullAccess

    /// The mode a chat starts in for `preferred`: Supervised when the agent can't
    /// use that, or the first it can when it can't ask either.
    public static func resolved(_ preferred: PermissionMode, allowed: [PermissionMode]?) -> PermissionMode {
        guard let allowed, !allowed.contains(preferred) else { return preferred }
        return allowed.contains(.supervised) || allowed.isEmpty ? .supervised : allowed[0]
    }
}
