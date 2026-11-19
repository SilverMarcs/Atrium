import Foundation

/// One repository in a project, seen through one of its checkouts.
public nonisolated struct GitRepositoryStatus: Codable, Sendable, Equatable {
    public var repositoryRootURL: URL
    public var branchName: String?
    public var localBranches: [String]
    public var worktrees: [GitWorktreeInfo] = []
    public var stagedFiles: [GitChangedFile]
    public var unstagedFiles: [GitChangedFile]
    public var unpushedCommits: [GitUnpushedCommit]
    public var remoteAheadCount: Int
    public var hasTrackingBranch: Bool

    public init(
        repositoryRootURL: URL,
        branchName: String? = nil,
        localBranches: [String],
        worktrees: [GitWorktreeInfo] = [],
        stagedFiles: [GitChangedFile],
        unstagedFiles: [GitChangedFile],
        unpushedCommits: [GitUnpushedCommit],
        remoteAheadCount: Int,
        hasTrackingBranch: Bool
    ) {
        self.repositoryRootURL = repositoryRootURL
        self.branchName = branchName
        self.localBranches = localBranches
        self.worktrees = worktrees
        self.stagedFiles = stagedFiles
        self.unstagedFiles = unstagedFiles
        self.unpushedCommits = unpushedCommits
        self.remoteAheadCount = remoteAheadCount
        self.hasTrackingBranch = hasTrackingBranch
    }

    public var isDirty: Bool {
        !stagedFiles.isEmpty || !unstagedFiles.isEmpty
    }

    /// Stable identity for a repository regardless of which worktree is in view:
    /// the main worktree's root. Keeps repo selection intact across worktree switches.
    public var mainRepositoryURL: URL {
        guard let main = worktrees.first(where: { $0.isMain }) else { return repositoryRootURL }
        return main.path.standardizedFileURL
    }

    public var isLinkedWorktree: Bool {
        worktrees.contains { $0.isCurrent && !$0.isMain }
    }

    public var name: String { mainRepositoryURL.lastPathComponent }
}

public nonisolated struct GitWorktreeInfo: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var path: URL
    /// Short branch name (e.g. "feature"), or nil when detached or bare.
    public var branch: String?
    /// Checked-out commit hash, or nil for a bare entry.
    public var head: String?
    public var isBare: Bool = false
    public var isDetached: Bool = false
    public var isLocked: Bool = false
    /// True for the primary worktree (the original clone). `git worktree list` always
    /// reports it first. Its branch belongs with normal branches, not the linked set.
    public var isMain: Bool = false
    /// True for the worktree whose root the enclosing snapshot represents.
    public var isCurrent: Bool = false

    public init(
        path: URL,
        branch: String? = nil,
        head: String? = nil,
        isBare: Bool = false,
        isDetached: Bool = false,
        isLocked: Bool = false,
        isMain: Bool = false,
        isCurrent: Bool = false
    ) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isMain = isMain
        self.isCurrent = isCurrent
    }

    public var id: String { path.path }
    public var displayName: String { path.lastPathComponent }

    public var deletionUnavailableReason: String? {
        if isMain || isBare { return "The main worktree cannot be deleted." }
        if isCurrent { return "Switch to another worktree before deleting this one." }
        if isLocked { return "Unlock this worktree before deleting it." }
        return nil
    }
}

public nonisolated struct GitUnpushedCommit: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { hash }
    public var hash: String
    public var message: String

    public init(hash: String, message: String) {
        self.hash = hash
        self.message = message
    }
}

public nonisolated struct GitLogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { hash }
    public var hash: String
    public var shortHash: String
    public var author: String
    public var date: Date?
    public var subject: String

    public init(hash: String, shortHash: String, author: String, date: Date? = nil, subject: String) {
        self.hash = hash
        self.shortHash = shortHash
        self.author = author
        self.date = date
        self.subject = subject
    }
}

public nonisolated struct GitChangedFile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var fileURL: URL
    public var repositoryRelativePath: String
    public var kind: GitChangeKind

    public init(fileURL: URL, repositoryRelativePath: String, kind: GitChangeKind) {
        self.fileURL = fileURL
        self.repositoryRelativePath = repositoryRelativePath
        self.kind = kind
    }

    public var id: String { repositoryRelativePath }
    public var name: String { fileURL.lastPathComponent }
}

public nonisolated enum PullPreservingResult: String, Codable, Equatable, Sendable {
    case clean
    case wouldConflict
}

public nonisolated struct GitBranchInfo: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var name: String
    public var isCurrent: Bool
    public var upstream: String?
    public var isRemote: Bool = false
    public var isMergedIntoCurrentBranch: Bool = false
    public var isMergedIntoDefaultBranch: Bool = false

    public init(
        name: String,
        isCurrent: Bool,
        upstream: String? = nil,
        isRemote: Bool = false,
        isMergedIntoCurrentBranch: Bool = false,
        isMergedIntoDefaultBranch: Bool = false
    ) {
        self.name = name
        self.isCurrent = isCurrent
        self.upstream = upstream
        self.isRemote = isRemote
        self.isMergedIntoCurrentBranch = isMergedIntoCurrentBranch
        self.isMergedIntoDefaultBranch = isMergedIntoDefaultBranch
    }

    public var id: String { "\(isRemote ? "remote" : "local")/\(name)" }
}

public nonisolated struct GitBranchListing: Codable, Equatable, Sendable {
    public var branches: [GitBranchInfo] = []
    public var worktrees: [GitWorktreeInfo] = []
    /// The default branch merges are checked against, e.g. "main".
    public var mergeTarget: String?
    /// Linked worktrees whose commits are all in the default branch and that
    /// have no uncommitted changes.
    public var mergedWorktrees: Set<URL> = []

    public init(
        branches: [GitBranchInfo] = [],
        worktrees: [GitWorktreeInfo] = [],
        mergeTarget: String? = nil,
        mergedWorktrees: Set<URL> = []
    ) {
        self.branches = branches
        self.worktrees = worktrees
        self.mergeTarget = mergeTarget
        self.mergedWorktrees = mergedWorktrees
    }

    public var linkedWorktrees: [GitWorktreeInfo] { worktrees.filter { !$0.isMain && !$0.isBare } }
    public var localBranches: [GitBranchInfo] {
        let checkedOut = Set(linkedWorktrees.compactMap(\.branch))
        return branches.filter { !$0.isRemote && !checkedOut.contains($0.name) }
    }
    public var remoteBranches: [GitBranchInfo] { branches.filter(\.isRemote) }

    public func isMerged(_ worktree: GitWorktreeInfo) -> Bool {
        mergedWorktrees.contains(worktree.path)
    }

    public func deletionUnavailableReason(for branch: GitBranchInfo) -> String? {
        if branch.isRemote { return "Remote branches cannot be deleted here." }
        if branch.isCurrent { return "Switch to another branch before deleting this one." }
        if let worktree = worktrees.first(where: { $0.branch == branch.name }) {
            return "This branch is checked out at \(worktree.path.path). Switch that worktree to another branch or remove the linked worktree first."
        }
        return nil
    }
}

public nonisolated enum GitDiffStage: Hashable, Codable, Sendable {
    case staged
    case unstaged
    case commit(hash: String)
}

public nonisolated struct GitDiffReference: Hashable, Codable, Sendable {
    public var repositoryRootURL: URL
    public var fileURL: URL
    public var repositoryRelativePath: String
    public var stage: GitDiffStage
    public var kind: GitChangeKind

    public init(
        repositoryRootURL: URL,
        fileURL: URL,
        repositoryRelativePath: String,
        stage: GitDiffStage,
        kind: GitChangeKind
    ) {
        self.repositoryRootURL = repositoryRootURL
        self.fileURL = fileURL
        self.repositoryRelativePath = repositoryRelativePath
        self.stage = stage
        self.kind = kind
    }
}

/// The checkout a task's agent works in: a linked worktree of its project's
/// repository, or that repository's main checkout.
public nonisolated struct TaskCheckout: Codable, Sendable, Hashable {
    /// Root of the repository's main checkout.
    public var repository: URL
    /// Root of the linked worktree, or nil for the main checkout.
    public var worktree: URL?

    public init(repository: URL, worktree: URL? = nil) {
        self.repository = repository
        self.worktree = worktree
    }
}
