/// Where in its project's repository a new task works, when not in the
/// project folder as it is.
public nonisolated enum TaskStartCheckout: Codable, Sendable, Hashable {
    /// A new linked worktree from the checked-out commit, which the agent
    /// creates and names the way it does on its own.
    case newWorktree
    /// A new branch from the checked-out one, switched to in the project folder.
    case newBranch(String)
}
