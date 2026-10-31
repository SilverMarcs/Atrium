import AtriumClient
import AtriumProtocol
import SwiftUI

/// The title menu of a project's pages: branches and linked worktrees, a new
/// branch, and the other repositories in the project when there's more than one.
struct BranchMenuItems: View {
    @Bindable var source: SourceControl
    let status: GitRepositoryStatus
    var onNewBranch: (() -> Void)?

    /// New Branch stays out of the menu for now.
    private static let showsNewBranch = false

    /// Whether there's another branch, worktree or repository to pick.
    static func hasChoices(in status: GitRepositoryStatus, repositories: [GitRepositoryStatus]?) -> Bool {
        status.localBranches.contains { $0 != status.branchName } || (repositories?.count ?? 0) > 1
    }

    var body: some View {
        let linkedBranches = Set(status.worktrees.filter { !$0.isMain && !$0.isBare }.compactMap(\.branch))
        let branches = status.localBranches.filter { !linkedBranches.contains($0) }
        let worktrees = status.localBranches.filter { linkedBranches.contains($0) }

        ForEach(branches, id: \.self) { branch in
            BranchMenuItem(source: source, status: status, branch: branch, isWorktree: false)
        }

        if !branches.isEmpty && !worktrees.isEmpty {
            Divider()
        }

        ForEach(worktrees, id: \.self) { branch in
            BranchMenuItem(source: source, status: status, branch: branch, isWorktree: true)
        }

        if Self.showsNewBranch, let onNewBranch {
            if !branches.isEmpty || !worktrees.isEmpty {
                Divider()
            }
            Button("New Branch…", systemImage: "plus", action: onNewBranch)
        }

        if let repositories = source.repositories, repositories.count > 1 {
            if !branches.isEmpty || !worktrees.isEmpty || (Self.showsNewBranch && onNewBranch != nil) {
                Divider()
            }
            Menu("Repository", systemImage: "folder") {
                RepositoryPicker(repositories: repositories, selection: Binding(
                    get: { Optional(status.mainRepositoryURL) },
                    set: { source.scope.selectedRepository = $0 }
                ))
            }
        }
    }
}
