import SwiftUI

/// Remote operations for the selected repository.
struct SourceControlActionsMenu: View {
    @Environment(CompanionClient.self) private var client
    let workspaceID: UUID
    let status: WireGitStatus?

    var body: some View {
        Menu {
            Button("Push", systemImage: "arrow.up") { send(.push) }
                .disabled(status.map { $0.unpushedCommits.isEmpty && $0.hasTrackingBranch } ?? true)
            Button("Pull", systemImage: "arrow.down") { send(.pull) }
                .disabled(status?.hasTrackingBranch != true)
            Button("Fetch", systemImage: "arrow.clockwise") { send(.fetch) }
        } label: {
            Label("Actions", systemImage: "point.topleft.down.curvedto.point.bottomright.up.fill")
        }
        .disabled(status?.hasRepository != true)
    }

    private func send(_ action: CompanionGitAction) {
        client.send(.git(workspaceID: workspaceID, action: action))
    }
}
