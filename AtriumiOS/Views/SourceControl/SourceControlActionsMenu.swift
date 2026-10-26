import SwiftUI

/// Committing and remote operations for the selected repository.
struct SourceControlActionsMenu: View {
    @Environment(CompanionClient.self) private var client
    let workspaceID: UUID
    let status: WireGitStatus?
    /// Asks for a message to commit the staged changes with.
    let onCommit: () -> Void

    var body: some View {
        Menu {
            Button("Push", systemImage: "arrow.up") { send(.push) }
                .disabled(status.map { $0.unpushedCommits.isEmpty && $0.hasTrackingBranch } ?? true)
            Button("Pull", systemImage: "arrow.down") { send(.pull) }
                .disabled(status?.hasTrackingBranch != true)
            Button("Fetch", systemImage: "arrow.clockwise") { send(.fetch) }

            Divider()

            Button("Commit…", systemImage: "checkmark", action: onCommit)
                .disabled(status?.stagedFiles.isEmpty != false)
        } label: {
            Label("Actions", systemImage: "point.topleft.down.curvedto.point.bottomright.up.fill")
        }
        .disabled(status?.hasRepository != true)
    }

    private func send(_ action: CompanionGitAction) {
        client.send(.git(workspaceID: workspaceID, action: action))
    }
}
