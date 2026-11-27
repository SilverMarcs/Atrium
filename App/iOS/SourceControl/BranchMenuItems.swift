import SwiftUI

/// The title menu of a project's pages: the branches and linked worktrees of
/// the repository shown, a new branch, and the project's other folders when
/// it has more than one.
struct BranchMenuItems: View {
    @Bindable var source: SourceControl
    /// The repository shown, or nil for a plain folder or one a task's worktree locks.
    let status: GitRepositoryStatus?
    var onNewBranch: (() -> Void)?

    /// New Branch stays out of the menu for now.
    private static let showsNewBranch = false

    /// Whether there's another branch, worktree or folder to pick.
    static func hasChoices(in status: GitRepositoryStatus?, folderCount: Int) -> Bool {
        folderCount > 1 || status.map { status in status.localBranches.contains { $0 != status.branchName } } ?? false
    }

    var body: some View {
        let linkedBranches = Set(status?.worktrees.filter { !$0.isMain && !$0.isBare }.compactMap(\.branch) ?? [])
        let localBranches = status?.localBranches ?? []
        let branches = localBranches.filter { !linkedBranches.contains($0) }
        let worktrees = localBranches.filter { linkedBranches.contains($0) }

        if let status {
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
        }

        if source.scope.pickableFolderCount > 1 {
            if !branches.isEmpty || !worktrees.isEmpty || (status != nil && Self.showsNewBranch && onNewBranch != nil) {
                Divider()
            }
            Menu("Folder", systemImage: "folder") {
                FolderPicker(scope: source.scope, selection: Binding(
                    get: { source.scope.selected?.key },
                    set: { source.scope.selectedFolder = $0 }
                ))
            }
        }
    }
}
