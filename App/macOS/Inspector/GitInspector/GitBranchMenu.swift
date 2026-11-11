import AtriumProtocol
import SwiftUI

struct GitBranchMenu: View {
    let branch: GitBranchInfo
    let model: GitBranchListModel
    let onCompare: (GitBranchInfo) -> Void

    var body: some View {
        Menu("Merge With", systemImage: "arrow.triangle.merge") {
            Section("Local") {
                ForEach(model.listing.localBranches) { target in
                    GitBranchMergeButton(source: branch, target: target, model: model)
                }
            }
            Section("Worktrees") {
                ForEach(model.listing.linkedWorktrees) { worktree in
                    if let target = model.listing.branch(for: worktree) {
                        GitBranchMergeButton(source: branch, target: target, model: model)
                    }
                }
            }
            Section("Remote") {
                ForEach(model.listing.remoteBranches) { target in
                    GitBranchMergeButton(source: branch, target: target, model: model)
                }
            }
        }
        .disabled(model.isBusy)

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
