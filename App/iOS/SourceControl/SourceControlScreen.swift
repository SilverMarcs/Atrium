import AtriumClient
import AtriumProtocol
import SwiftUI

/// Source control for one project: unpushed commits, staged and working
/// changes, each shown only when non-empty. The list and toolbars stay in place
/// while loading, so only the list's contents change when the status arrives.
/// The title menu switches branches and repositories; the actions menu commits
/// and runs remote operations.
struct SourceControlScreen: View {
    @State private var source: SourceControl
    @State private var commitMessage = ""
    @State private var showingCommit = false
    @State private var showingNewBranch = false
    @State private var newBranchName = ""

    init(host: HostClient, workspaceID: UUID) {
        _source = State(initialValue: SourceControl(host: host, workspaceID: workspaceID))
    }

    var body: some View {
        let status = source.status
        SourceControlChangesList(source: source) { showingCommit = true }
            .refreshable {
                if let status { await source.fetch(status) }
            }
            .projectScopeTitle(source, placeholder: "Source Control") {
                showingNewBranch = true
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SourceControlActionsMenu(source: source) { showingCommit = true }
                }
            }
            .alert("Commit", isPresented: $showingCommit) {
                TextField("Commit message", text: $commitMessage)
                Button("Commit", action: commit)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Commit the staged changes to “\(status?.branchName ?? "HEAD")”.")
            }
            .alert("New Branch", isPresented: $showingNewBranch) {
                TextField("Branch name", text: $newBranchName)
                Button("Create", action: createBranch)
                Button("Cancel", role: .cancel) { newBranchName = "" }
            } message: {
                Text("Create a branch from “\(status?.branchName ?? "HEAD")”.")
            }
    }

    private func commit() {
        guard let status = source.status else { return }
        let message = commitMessage
        commitMessage = ""
        Task { await source.commit(message: message, in: status) }
    }

    private func createBranch() {
        let name = newBranchName
        newBranchName = ""
        guard let status = source.status else { return }
        Task { await source.createBranch(named: name, in: status) }
    }
}
