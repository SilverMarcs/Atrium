import AtriumProtocol
import SwiftUI

/// A native checked menu item that keeps the selected checkout selected.
struct BranchMenuItem: View {
    let source: SourceControl
    let status: GitRepositoryStatus
    let branch: String
    let isWorktree: Bool

    var body: some View {
        Toggle(isOn: Binding(
            get: { status.branchName == branch },
            set: { isSelected in
                if isSelected { source.selectBranch(branch, in: status) }
            }
        )) {
            Label(branch, systemImage: isWorktree ? "folder" : "arrow.triangle.branch")
        }
        .accessibilityLabel(isWorktree ? "Worktree, \(branch)" : "Branch, \(branch)")
    }
}
