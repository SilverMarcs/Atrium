import AtriumClient
import AtriumProtocol
import SwiftUI

/// A remote control for the project's saved commands on its host. Output stays
/// in the host's Commands inspector.
struct CommandsScreen: View {
    let host: HostClient
    let workspaceID: UUID

    private var commands: [WireCommand]? { host.commands[workspaceID] }

    var body: some View {
        List(commands ?? []) { command in
            CommandRow(command: command) {
                // Runs in the checkout the project's other pages show.
                let run = CommandAction.run(directory: host.scope(for: workspaceID).root.filePath)
                host.send(.command(workspaceID: workspaceID, commandID: command.id, action: command.isRunning ? .stop : run))
            }
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
                    description: Text("Add commands in the Commands inspector on \(host.name).")
                )
            }
        }
        .navigationTitle(host.workspace(workspaceID)?.name ?? "Commands")
        .toolbarTitleDisplayMode(.inline)
        .task(id: workspaceID) {
            await host.follow(.commands(workspaceID: workspaceID))
        }
    }
}
