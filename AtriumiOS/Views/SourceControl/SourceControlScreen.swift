import SwiftUI

/// Source control for one project: unpushed commits, staged and working
/// changes, each shown only when non-empty. The list and toolbars stay in place
/// while loading, so only the list's contents change when the status arrives.
/// The title menu switches branches; the actions menu commits and runs remote
/// operations.
struct SourceControlScreen: View {
    @Environment(CompanionClient.self) private var client
    let workspaceID: UUID

    @State private var commitMessage = ""
    @State private var showingCommit = false
    @State private var showingNewBranch = false
    @State private var newBranchName = ""
    @State private var showingInfo = false
    @State private var pendingDiscard: SourceControlDiscard?

    /// The repository info button is hidden for now; its sheet stays wired up.
    private static let showsInfoButton = false

    private var status: WireGitStatus? { client.gitStatuses[workspaceID] }

    var body: some View {
        SourceControlChangesList(workspaceID: workspaceID, status: status) { pendingDiscard = $0 }
        .refreshable { await client.perform(.git(workspaceID: workspaceID, action: .refresh)) }
        .navigationTitle(status?.branchName ?? "Source Control")
        .toolbarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            if let status, status.hasRepository {
                BranchMenuItems(workspaceID: workspaceID, status: status) { showingNewBranch = true }
            }
        }
        .toolbar {
            if Self.showsInfoButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Info", systemImage: "info") { showingInfo = true }
                        .disabled(status?.hasRepository != true)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                SourceControlActionsMenu(workspaceID: workspaceID, status: status) { showingCommit = true }
            }
        }
        .sheet(isPresented: $showingInfo) {
            if let status { SourceControlInfoSheet(status: status) }
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
            Button("Discard", role: .destructive) {
                client.send(.git(workspaceID: workspaceID, action: discard.action))
            }
            Button("Cancel", role: .cancel) {}
        } message: { discard in
            Text(discard.message)
        }
        .task(id: workspaceID) {
            await client.follow(.git(workspaceID: workspaceID))
        }
    }

    private func commit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, status?.stagedFiles.isEmpty == false else { return }
        client.send(.git(workspaceID: workspaceID, action: .commit(message: message)))
        commitMessage = ""
    }

    private func createBranch() {
        let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        newBranchName = ""
        guard !name.isEmpty else { return }
        client.send(.git(workspaceID: workspaceID, action: .createBranch(name: name)))
    }
}
