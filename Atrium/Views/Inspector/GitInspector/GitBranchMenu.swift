import SwiftUI

struct GitBranchMenu: View {
    let branch: GitBranchInfo
    let model: GitBranchListModel
    let onCompare: (GitBranchInfo) -> Void

    var body: some View {
        if !branch.isCurrent, let head = model.listing.currentBranchName {
            if branch.upstream != nil {
                Button("Sync with Upstream", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await model.sync(branch) }
                }
                .disabled(model.isBusy)
                Divider()
            }
            Button("Compare Commits with \(head)…", systemImage: "arrow.left.arrow.right") {
                onCompare(branch)
            }
        }
        if model.unavailableReason(for: .deleteBranch(branch)) == nil {
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await model.request(.deleteBranch(branch)) }
            }
            .disabled(model.isBusy)
        }
    }
}
