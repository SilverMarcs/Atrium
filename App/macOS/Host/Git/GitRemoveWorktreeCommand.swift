import Foundation

struct GitRemoveWorktreeCommand: GitCommand {
    let worktreeURL: URL
    /// Removes the worktree even with modified or untracked files. Locked
    /// worktrees still refuse, since that needs a second `--force`.
    var force = false

    var arguments: [String] {
        ["worktree", "remove"] + (force ? ["--force"] : []) + ["--", worktreeURL.path]
    }

    func parse(output: String) throws {}
}
