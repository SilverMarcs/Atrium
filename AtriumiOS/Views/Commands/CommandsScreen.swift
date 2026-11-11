import AtriumClient
import AtriumProtocol
import SwiftUI

/// The project's saved commands on its host. Each runs there in the checkout
/// the project's other pages show, and opens to its output and input.
struct CommandsScreen: View {
    let host: HostClient
    let workspaceID: UUID

    private var commands: [WireCommand]? { host.commands[workspaceID] }

    var body: some View {
        List(commands ?? []) { command in
            NavigationLink(value: Route.command(WorkspaceRef(hostID: host.id, workspaceID: workspaceID), commandID: command.id)) {
                CommandRow(command: command) { host.toggle(command, in: workspaceID) }
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
