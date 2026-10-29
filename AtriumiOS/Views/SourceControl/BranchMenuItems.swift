import AtriumProtocol
import SwiftUI

/// The source control title menu: branches and linked worktrees, a new branch,
/// and the other repositories in the project when there's more than one.
struct BranchMenuItems: View {
    @Bindable var source: SourceControl
    let status: GitRepositoryStatus
    let onNewBranch: () -> Void

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

        if !branches.isEmpty || !worktrees.isEmpty {
            Divider()
        }

        Button("New Branch…", systemImage: "plus", action: onNewBranch)

        if let repositories = source.repositories, repositories.count > 1 {
            Divider()
            Menu("Repository", systemImage: "folder") {
                RepositoryPicker(repositories: repositories, selection: Binding(
                    get: { status.mainRepositoryURL },
                    set: { source.selectedRepository = $0 }
                ))
            }
        }
    }
}
