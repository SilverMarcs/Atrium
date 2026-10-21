import Foundation

nonisolated struct GitBranchListing: Equatable, Sendable {
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
