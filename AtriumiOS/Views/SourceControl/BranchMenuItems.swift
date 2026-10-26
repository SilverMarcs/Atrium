import SwiftUI

/// The source control title menu: the repository's branches to switch to, a new
/// branch, and the other repositories in the project when there's more than one.
struct BranchMenuItems: View {
    @Environment(CompanionClient.self) private var client
    let workspaceID: UUID
    let status: WireGitStatus
    let onNewBranch: () -> Void

    var body: some View {
        Picker("Branch", selection: Binding(
            get: { status.branchName ?? "" },
            set: { branch in
                guard !branch.isEmpty, branch != status.branchName else { return }
                client.send(.git(workspaceID: workspaceID, action: .switchBranch(name: branch)))
            }
        )) {
            ForEach(status.localBranches, id: \.self) { branch in
                Label(branch, systemImage: "arrow.triangle.branch")
                    .tag(branch)
            }
        }

        Button("New Branch…", systemImage: "plus", action: onNewBranch)

        if status.repositories.count > 1 {
            Divider()
            Menu("Repository", systemImage: "folder") {
                RepositoryPicker(status: status) { path in
                    client.send(.git(workspaceID: workspaceID, action: .selectRepository(path: path)))
                }
            }
        }
    }
}
