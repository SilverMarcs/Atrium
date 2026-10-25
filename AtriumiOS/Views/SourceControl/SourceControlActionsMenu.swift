import SwiftUI

/// Remote operations and branches for the selected repository.
struct SourceControlActionsMenu: View {
    @Environment(CompanionClient.self) private var client
    let workspaceID: UUID
    let status: WireGitStatus
    let onNewBranch: () -> Void

    var body: some View {
        Menu {
            Button("Push", systemImage: "arrow.up") { send(.push) }
                .disabled(status.unpushedCommits.isEmpty && status.hasTrackingBranch)
            Button("Pull", systemImage: "arrow.down") { send(.pull) }
                .disabled(!status.hasTrackingBranch)
            Button("Fetch", systemImage: "arrow.clockwise") { send(.fetch) }

            Divider()

            Menu("Switch Branch", systemImage: "arrow.triangle.branch") {
                ForEach(status.localBranches, id: \.self) { branch in
                    Button(branch) { send(.switchBranch(name: branch)) }
                        .disabled(branch == status.branchName)
                }
            }
            .disabled(status.localBranches.count < 2)
            Button("New Branch", systemImage: "plus", action: onNewBranch)
        } label: {
            Label("Actions", systemImage: "point.topleft.down.curvedto.point.bottomright.up.fill")
        }
    }

    private func send(_ action: CompanionGitAction) {
        client.send(.git(workspaceID: workspaceID, action: action))
    }
}
