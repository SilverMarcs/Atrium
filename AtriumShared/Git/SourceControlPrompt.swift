import AtriumProtocol
import Foundation

/// What a source control operation needs confirmed before it goes on, or why
/// it couldn't.
enum SourceControlPrompt {
    /// Some working-tree files, or every working-tree change when nil.
    case discard([GitChangedFile]?, GitRepositoryStatus)
    /// The main worktree has uncommitted changes to stash before it switches
    /// branch. `isOtherWorktree` when a linked worktree is in view instead.
    case stashAndSwitch(branch: String, repository: URL, isOtherWorktree: Bool)
    /// The branch isn't on the remote yet.
    case publish(GitRepositoryStatus)
    /// The local branch and the remote have both moved on.
    case diverged(GitRepositoryStatus)
    /// Pulling would conflict with uncommitted changes, so nothing changed.
    case pullConflict

    var title: String {
        switch self {
        case .discard: "Discard Changes?"
        case .stashAndSwitch: "Stash Changes?"
        case .publish: "Publish Branch?"
        case .diverged: "Branches Diverged"
        case .pullConflict: "Cannot Pull Cleanly"
        }
    }

    var message: String {
        switch self {
        case .discard(let files, _):
            if let files, files.count == 1, let file = files.first {
                "This discards your changes to “\(file.repositoryRelativePath)”. It can’t be undone."
            } else if let files {
                "This discards your changes to \(files.count) files. It can’t be undone."
            } else {
                "This discards every working-tree change. It can’t be undone."
            }
        case .stashAndSwitch(let branch, _, let isOtherWorktree):
            if isOtherWorktree {
                "The main worktree has uncommitted changes. Stash them, including staged and untracked files, before switching it to “\(branch)”?"
            } else {
                "You have uncommitted changes. Stash them, including staged and untracked files, before switching to “\(branch)”?"
            }
        case .publish(let snapshot):
            "The branch “\(snapshot.branchName ?? "")” doesn’t exist on the remote. Publishing creates it there and pushes your commits."
        case .diverged:
            "Your local branch and the remote have both moved forward. Rebase your local commits onto the remote to sync."
        case .pullConflict:
            "Pulling would create merge conflicts with your uncommitted changes, so your working tree was left untouched. Commit or stash your changes, then try again."
        }
    }

    /// The button that goes ahead, or nil when there's nothing to go ahead with.
    var confirmTitle: String? {
        switch self {
        case .discard: "Discard"
        case .stashAndSwitch: "Stash & Switch"
        case .publish: "Publish"
        case .diverged: "Rebase"
        case .pullConflict: nil
        }
    }

    var isDestructive: Bool {
        if case .discard = self { return true }
        return false
    }
}
