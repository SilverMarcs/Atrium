import AtriumClient
import AtriumProtocol
import SwiftUI

/// Source control for one project: unpushed commits, staged and working
/// changes, each shown only when non-empty. The list and toolbars stay in place
/// while loading, so only the list's contents change when the status arrives.
/// The title menu switches branches; the actions menu commits and runs remote
/// operations.
struct SourceControlScreen: View {
    @State private var source: SourceControl
    @State private var commitMessage = ""
    @State private var showingCommit = false
    @State private var showingNewBranch = false
    @State private var newBranchName = ""
    @State private var pendingDiscard: SourceControlDiscard?

    init(host: HostClient, workspaceID: UUID) {
        _source = State(initialValue: SourceControl(host: host, workspaceID: workspaceID))
    }

    var body: some View {
        let status = source.status
        SourceControlChangesList(source: source, onCommit: { showingCommit = true }) { pendingDiscard = $0 }
            .refreshable {
                if let status { await source.perform(.fetch, in: status.mainRepositoryURL) }
            }
            .navigationTitle(status?.branchName ?? "Source Control")
            .toolbarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                if let status {
                    BranchMenuItems(source: source, status: status) { showingNewBranch = true }
                }
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
            .alert(
                "Discard Changes?",
                isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
                presenting: pendingDiscard
            ) { discard in
                Button("Discard", role: .destructive) { source.send(discard.operation) }
                Button("Cancel", role: .cancel) {}
            } message: { discard in
                Text(discard.message)
            }
            .task(id: source.scope) {
                await source.host.follow(.git(source.scope))
            }
    }

    private func commit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, source.status?.stagedFiles.isEmpty == false else { return }
        source.send(.commit(message: message))
        commitMessage = ""
    }

    private func createBranch() {
        let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        newBranchName = ""
        guard !name.isEmpty else { return }
        source.send(.createBranch(name))
    }
}
