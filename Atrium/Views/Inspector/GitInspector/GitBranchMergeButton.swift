import AtriumProtocol
import SwiftUI

struct GitBranchMergeButton: View {
    let source: GitBranchInfo
    let target: GitBranchInfo
    let model: GitBranchListModel

    var body: some View {
        Button(target.name) {
            Task { await model.merge(source, into: target) }
        }
        .disabled(target.id == source.id || target.isRemote)
        .help(target.isRemote ? "Merge into a local branch, then push it to update the remote." : "Merge \(source.name) into \(target.name)")
    }
}
