import SwiftUI

/// Source control for one project: unpushed commits, staged and working
/// changes, each shown only when non-empty. The title menu picks among the
/// repositories found in the project; the bottom bar holds the commit field,
/// remote operations and the project's commands.
struct SourceControlScreen: View {
    @Environment(CompanionClient.self) private var client
    let workspaceID: UUID

    @State private var commitMessage = ""
    @State private var isCommitFieldFocused = false
    @State private var showingNewBranch = false
    @State private var newBranchName = ""
    @State private var showingInfo = false
    @State private var pendingDiscard: SourceControlDiscard?

    private var status: WireGitStatus? { client.gitStatuses[workspaceID] }

    var body: some View {
        Group {
            if let status, status.hasRepository {
                SourceControlChangesList(workspaceID: workspaceID, status: status) { pendingDiscard = $0 }
            } else if status == nil {
                ProgressView()
                    .controlSize(.large)
            } else {
                ContentUnavailableView(
                    "No Repository",
                    systemImage: "arrow.triangle.branch",
                    description: Text("This project folder isn’t a Git repository.")
                )
            }
        }
        .refreshable { await client.perform(.git(workspaceID: workspaceID, action: .refresh)) }
        .navigationTitle(status?.branchName ?? "Source Control")
        .toolbarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            if let status, !status.repositories.isEmpty {
                RepositoryPicker(status: status) { path in
                    client.send(.git(workspaceID: workspaceID, action: .selectRepository(path: path)))
                }
            }
        }
        .searchable(text: $commitMessage, isPresented: $isCommitFieldFocused, prompt: "Commit message")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .onSubmit(of: .search, commit)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Info", systemImage: "info") { showingInfo = true }
                    .disabled(status?.hasRepository != true)
            }
            ToolbarItem(placement: .bottomBar) {
                NavigationLink(value: Route.commands(workspaceID)) {
                    Label("Commands", systemImage: "terminal")
                }
            }
            ToolbarSpacer(.fixed, placement: .bottomBar)
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            if let status, status.hasRepository {
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    SourceControlActionsMenu(workspaceID: workspaceID, status: status) { showingNewBranch = true }
                }
            }
        }
        .sheet(isPresented: $showingInfo) {
            if let status { SourceControlInfoSheet(status: status) }
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
        isCommitFieldFocused = false
    }

    private func createBranch() {
        let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        newBranchName = ""
        guard !name.isEmpty else { return }
        client.send(.git(workspaceID: workspaceID, action: .createBranch(name: name)))
    }
}
