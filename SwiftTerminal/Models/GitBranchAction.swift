import Foundation

/// The one confirmation currently presented by the branch manager.
enum GitBranchAction {
    case deleteBranch(GitBranchInfo)
    case deleteWorktree(GitWorktreeInfo)
    case convertWorktree(GitWorktreeInfo)

    var title: String {
        switch self {
        case .deleteBranch: "Delete Unmerged Branch?"
        case .deleteWorktree: "Delete Worktree?"
        case .convertWorktree: "Convert to Branch?"
        }
    }

    var buttonTitle: String { isDestructive ? "Delete" : "Convert" }

    var isDestructive: Bool {
        if case .convertWorktree = self { return false }
        return true
    }

    var message: String {
        switch self {
        case .deleteBranch(let branch):
            "\"\(branch.name)\" is not fully merged into the current branch. Deleting it may discard commits permanently."
        case .deleteWorktree(let worktree):
            if let branch = worktree.branch {
                "This deletes the folder at \(worktree.path.path) and the local branch \"\(branch)\". Unmerged commits may be lost. Worktrees with uncommitted changes cannot be deleted."
            } else {
                "This removes the folder at \(worktree.path.path). Detached commits not saved on a branch may become unreachable. Worktrees with uncommitted changes cannot be deleted."
            }
        case .convertWorktree(let worktree):
            "This switches the main checkout to \"\(worktree.branch ?? "")\" and removes the worktree folder at \(worktree.path.path). The branch and its commits are kept. Both checkouts must have no uncommitted changes."
        }
    }
}
