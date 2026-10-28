import Foundation

/// One repository in a project, seen through one of its checkouts.
nonisolated struct GitRepositoryStatus: Codable, Sendable, Equatable {
    var repositoryRootURL: URL
    var branchName: String?
    var localBranches: [String]
    var worktrees: [GitWorktreeInfo] = []
    var stagedFiles: [GitChangedFile]
    var unstagedFiles: [GitChangedFile]
    var unpushedCommits: [GitUnpushedCommit]
    var remoteAheadCount: Int
    var hasTrackingBranch: Bool

    var isDirty: Bool {
        !stagedFiles.isEmpty || !unstagedFiles.isEmpty
    }

    /// Stable identity for a repository regardless of which worktree is in view:
    /// the main worktree's root. Keeps repo selection intact across worktree switches.
    var mainRepositoryURL: URL {
        guard let main = worktrees.first(where: { $0.isMain }) else { return repositoryRootURL }
        return main.path.standardizedFileURL
    }

    var isLinkedWorktree: Bool {
        worktrees.contains { $0.isCurrent && !$0.isMain }
    }

    var name: String { mainRepositoryURL.lastPathComponent }
}

nonisolated struct GitWorktreeInfo: Codable, Equatable, Hashable, Identifiable, Sendable {
    var path: URL
    /// Short branch name (e.g. "feature"), or nil when detached or bare.
    var branch: String?
    /// Checked-out commit hash, or nil for a bare entry.
    var head: String?
    var isBare: Bool = false
    var isDetached: Bool = false
    var isLocked: Bool = false
    /// True for the primary worktree (the original clone). `git worktree list` always
    /// reports it first. Its branch belongs with normal branches, not the linked set.
    var isMain: Bool = false
    /// True for the worktree whose root the enclosing snapshot represents.
    var isCurrent: Bool = false

    var id: String { path.path }
    var displayName: String { path.lastPathComponent }

    var deletionUnavailableReason: String? {
        if isMain || isBare { return "The main worktree cannot be deleted." }
        if isCurrent { return "Switch to another worktree before deleting this one." }
        if isLocked { return "Unlock this worktree before deleting it." }
        return nil
    }
}

nonisolated struct GitUnpushedCommit: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { hash }
    var hash: String
    var message: String
}

nonisolated struct GitLogEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String { hash }
    var hash: String
    var shortHash: String
    var author: String
    var date: Date?
    var subject: String
}

nonisolated struct GitStashEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    var index: Int
    var hash: String
    var branch: String?
    var message: String
    var date: Date?
    var id: String { hash }
}

nonisolated struct GitChangedFile: Codable, Equatable, Hashable, Identifiable, Sendable {
    var fileURL: URL
    var repositoryRelativePath: String
    var kind: GitChangeKind

    var id: String { repositoryRelativePath }
    var name: String { fileURL.lastPathComponent }
}

nonisolated enum PullPreservingResult: String, Codable, Equatable, Sendable {
    case clean
    case wouldConflict
}

nonisolated enum GitBranchSyncResult: String, Codable, Sendable {
    case alreadyUpToDate
    case synced
}

nonisolated struct GitBranchInfo: Codable, Equatable, Hashable, Identifiable, Sendable {
    var name: String
    var isCurrent: Bool
    var upstream: String?
    var isRemote = false
    var isMergedIntoCurrentBranch = false
    var isMergedIntoDefaultBranch = false

    var id: String { "\(isRemote ? "remote" : "local")/\(name)" }
}

nonisolated struct GitBranchListing: Codable, Equatable, Sendable {
    var branches: [GitBranchInfo] = []
    var worktrees: [GitWorktreeInfo] = []
    var mergeTarget: String?
    var mergedDetachedHeads: Set<String> = []

    var linkedWorktrees: [GitWorktreeInfo] { worktrees.filter { !$0.isMain && !$0.isBare } }
    var localBranches: [GitBranchInfo] {
        let checkedOut = Set(linkedWorktrees.compactMap(\.branch))
        return branches.filter { !$0.isRemote && !checkedOut.contains($0.name) }
    }
    var remoteBranches: [GitBranchInfo] { branches.filter(\.isRemote) }
    var currentBranchName: String? { branches.first(where: \.isCurrent)?.name }

    func branch(for worktree: GitWorktreeInfo) -> GitBranchInfo? {
        branches.first { !$0.isRemote && $0.name == worktree.branch }
    }

    func isMerged(_ worktree: GitWorktreeInfo) -> Bool {
        if let branch = branch(for: worktree) { return branch.isMergedIntoDefaultBranch }
        return worktree.head.map { mergedDetachedHeads.contains($0) } ?? false
    }

    func deletionUnavailableReason(for branch: GitBranchInfo) -> String? {
        if branch.isRemote { return "Remote branches cannot be deleted here." }
        if branch.isCurrent { return "Switch to another branch before deleting this one." }
        if let worktree = worktrees.first(where: { $0.branch == branch.name }) {
            return "This branch is checked out at \(worktree.path.path). Switch that worktree to another branch or remove the linked worktree first."
        }
        return nil
    }
}

nonisolated enum GitDiffStage: Hashable, Codable, Sendable {
    case staged
    case unstaged
    case commit(hash: String)
    case range(base: String, head: String)

    var displayName: String {
        switch self {
            case .staged: "Staged Changes"
            case .unstaged: "Changes"
            case .commit(let hash): "Commit \(String(hash.prefix(7)))"
            case .range(let base, let head): "\(base) → \(head)"
        }
    }
}

nonisolated struct GitDiffReference: Hashable, Codable, Sendable {
    var repositoryRootURL: URL
    var fileURL: URL
    var repositoryRelativePath: String
    var stage: GitDiffStage
    var kind: GitChangeKind
}

/// The checkout a task's agent works in: a linked worktree of its project's
/// repository, or that repository's main checkout.
nonisolated struct TaskCheckout: Codable, Sendable, Hashable {
    /// Root of the repository's main checkout.
    var repository: URL
    /// Root of the linked worktree, or nil for the main checkout.
    var worktree: URL?
}
