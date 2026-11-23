import Foundation

/// Runs a client's Git operation in one of a project's repositories.
enum GitService {
    static func handle(_ operation: GitOperation, in repository: URL, workspace: Workspace) async -> HostReply {
        let access = workspace.access
        guard access.allows(repository), operation.urls.allSatisfy(access.allows) else {
            return .failed(message: "That repository isn’t part of this project.")
        }
        do {
            return .git(try await perform(operation, in: repository))
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    private static func perform(_ operation: GitOperation, in root: URL) async throws -> GitReply {
        let git = GitRepository.shared
        switch operation {
        case .initialize:
            try await git.initializeRepository(at: root)
        case .stage(let paths):
            if !paths.isEmpty { try await git.stage(paths: paths, at: root) }
        case .unstage(let paths):
            if !paths.isEmpty { try await git.unstage(paths: paths, at: root) }
        case .discard(let tracked, let untracked):
            try await git.discardChanges(trackedPaths: tracked, untrackedPaths: untracked, at: root)
        case .discardAll:
            try await git.discardAllChanges(at: root)
        case .commit(let message):
            try await git.commit(message: message, at: root)
        case .push(let branch):
            if let branch {
                try await git.pushSetUpstream(branch: branch, at: root)
            } else {
                try await git.push(at: root)
            }
        case .pull:
            try await git.pull(at: root)
        case .pullPreservingChanges:
            return .pull(try await git.pullPreservingChanges(at: root))
        case .pullRebase:
            try await git.pullRebase(at: root)
        case .fetch:
            try await git.fetch(at: root)
        case .fetchIfStale:
            try? await git.fetchIfStale(at: root)
        case .switchBranch(let branch):
            try await git.switchBranch(to: branch, at: root)
            try? await git.fetchIfStale(at: root)
        case .createBranch(let name):
            try await git.createBranch(named: name, at: root)
        case .stash:
            try await git.stashAll(at: root)
        case .undoLastCommit:
            try await git.undoLastCommit(at: root)
        case .amendMessage(let message):
            try await git.amendCommitMessage(message, at: root)
        case .log(let limit):
            return .log(try await git.commitLog(at: root, limit: limit))
        case .commitFiles(let hash):
            return .files(try await git.changedFiles(forCommit: hash, at: root))
        case .compare(let base, let head):
            return .comparison(try await git.compare(base: base, head: head, at: root))
        case .branches:
            return .branches(try await git.allBranchesDetailed(at: root))
        case .deleteBranch(let name, let force):
            try await git.deleteBranch(name, force: force, at: root)
        case .deleteWorktree(let worktree, let force):
            try await git.deleteWorktree(at: worktree, in: root, force: force)
        case .hasUncommittedChanges:
            return .flag(await git.hasUncommittedChanges(at: root))
        case .applyPatch(let patch, let reverse, let cached):
            try await git.applyPatch(patch, reverse: reverse, cached: cached, at: root)
        case .diff(let reference):
            async let hunks = git.rawDiff(for: reference)
            async let fullContext = git.rawFullContextDiff(for: reference)
            let (hunkText, fullText) = try await (hunks, fullContext)
            guard hunkText.utf8.count + fullText.utf8.count <= HostProtocol.maxDiffBytes else {
                return .diff(hunks: "", fullContext: "")
            }
            return .diff(hunks: hunkText, fullContext: fullText)
        case .imageDiff(let reference):
            let images = await git.imageDiff(for: reference)
            return .images(old: images.old, new: images.new)
        case .gutterDiff(let file):
            let diff = try await git.gutterDiff(for: file, at: root)
            return .gutter(staged: diff.staged, unstaged: diff.unstaged)
        }
        return .done
    }
}

private extension GitOperation {
    /// Files and checkouts the operation names besides its repository, which
    /// must be part of the project too.
    var urls: [URL] {
        switch self {
        case .deleteWorktree(let url, _), .gutterDiff(let url): [url]
        case .diff(let reference), .imageDiff(let reference): [reference.repositoryRootURL]
        default: []
        }
    }
}
