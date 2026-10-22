import Foundation

struct GitRemoveWorktreeCommand: GitCommand {
    let worktreeURL: URL

    var arguments: [String] {
        ["worktree", "remove", "--", worktreeURL.path]
    }

    func parse(output: String) throws {}
}
