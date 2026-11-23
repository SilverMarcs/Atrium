import Foundation

/// Something to do in one of a project's repositories. Operations that change
/// a repository refresh the project's Git status for every client.
nonisolated enum GitOperation: Codable, Sendable {
    case initialize
    case stage(paths: [String])
    case unstage(paths: [String])
    case discard(tracked: [String], untracked: [String])
    case discardAll
    case commit(message: String)
    /// Pushes, publishing the branch first when it has one and no upstream yet.
    case push(branch: String?)
    case pull
    case pullPreservingChanges
    case pullRebase
    case fetch
    /// Fetches unless the repository was fetched recently, quietly.
    case fetchIfStale
    case switchBranch(String)
    case createBranch(String)
    /// Stashes every change, untracked files too, before a branch switch.
    case stash
    case undoLastCommit
    case amendMessage(String)
    case log(limit: Int)
    case commitFiles(hash: String)
    /// What `head` (a branch or commit, or the checkout with its uncommitted
    /// changes when nil) changed since it left `base`, or the repository's
    /// default branch when `base` is nil.
    case compare(base: String?, head: String?)
    case branches
    case deleteBranch(name: String, force: Bool)
    /// Deletes a linked worktree and its branch; `force` also discards its modified and untracked files.
    case deleteWorktree(URL, force: Bool)
    case hasUncommittedChanges
    case applyPatch(String, reverse: Bool, cached: Bool)
    /// A file's diff, as hunks and with full context.
    case diff(GitDiffReference)
    /// Both sides of an image's diff.
    case imageDiff(GitDiffReference)
    /// A working file's staged and unstaged changes, for the editor's gutter.
    case gutterDiff(file: URL)

    /// Whether the operation can change what `git status` reports.
    var changesStatus: Bool {
        switch self {
        case .log, .commitFiles, .compare, .branches, .hasUncommittedChanges, .diff, .imageDiff, .gutterDiff, .fetchIfStale:
            false
        default:
            true
        }
    }
}

nonisolated enum GitReply: Codable, Sendable {
    case done
    case flag(Bool)
    case files([GitChangedFile])
    case comparison(GitComparison)
    case log([GitLogEntry])
    case branches(GitBranchListing)
    case pull(PullPreservingResult)
    /// Unified diff text, by hunks and with full context.
    case diff(hunks: String, fullContext: String)
    case images(old: Data?, new: Data?)
    case gutter(staged: String, unstaged: String)
}
