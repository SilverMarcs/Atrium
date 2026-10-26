import SwiftUI

/// A remote control for the project's saved commands on the host. Output stays
/// in the host's Commands inspector.
struct CommandsScreen: View {
    @Environment(CompanionClient.self) private var client
    let workspaceID: UUID

    private var commands: [WireCommand]? { client.commands[workspaceID] }

    var body: some View {
        List(commands ?? []) { command in
            CommandRow(workspaceID: workspaceID, command: command)
        }
        .contentMargins(.top, 10)
        .overlay {
            if commands == nil {
                ProgressView()
                    .controlSize(.large)
            } else if commands?.isEmpty == true {
                ContentUnavailableView(
                    "No Commands",
                    systemImage: "terminal",
                    description: Text("Add commands in the Commands inspector on your host.")
                )
            }
        }
        .navigationTitle(client.workspace(workspaceID)?.name ?? "Commands")
        .toolbarTitleDisplayMode(.inline)
        .task(id: workspaceID) {
            await client.follow(.commands(workspaceID: workspaceID))
        }
    }
}
