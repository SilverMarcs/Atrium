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
    /// Fetches, then rebases onto the remote side of a branch.
    case rebase(onto: String)
    case fetch
    /// Fetches unless the repository was fetched recently, quietly.
    case fetchIfStale
    case switchBranch(String)
    case createBranch(String)
    case stash(message: String?)
    case canApplyStash
    case popStash
    case stashes
    case applyStash(index: Int)
    case dropStash(index: Int)
    case stashFiles(index: Int)
    case undoLastCommit
    case amendMessage(String)
    case log(limit: Int)
    case commitFiles(hash: String)
    case rangeFiles(base: String, head: String)
    case branches
    case mergeBranch(source: GitBranchInfo, target: GitBranchInfo)
    case deleteBranch(name: String, force: Bool)
    case deleteWorktree(URL)
    case convertWorktree(URL)
    case syncBranch(local: String, upstream: String)
    case hasUncommittedChanges
    case remoteURL
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
        case .canApplyStash, .stashes, .stashFiles, .log, .commitFiles, .rangeFiles, .branches,
             .hasUncommittedChanges, .remoteURL, .diff, .imageDiff, .gutterDiff, .fetchIfStale:
            false
        default:
            true
        }
    }
}

nonisolated enum GitReply: Codable, Sendable {
    case done
    case text(String)
    case flag(Bool)
    case files([GitChangedFile])
    case log([GitLogEntry])
    case stashes([GitStashEntry])
    case branches(GitBranchListing)
    case pull(PullPreservingResult)
    case sync(GitBranchSyncResult)
    /// Unified diff text, by hunks and with full context.
    case diff(hunks: String, fullContext: String)
    case images(old: Data?, new: Data?)
    case gutter(staged: String, unstaged: String)
}
