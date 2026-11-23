import SwiftUI

/// The project's saved commands on its host. Each runs there in the checkout
/// the project's other pages show, and opens to its output and input.
struct CommandsScreen: View {
    let host: HostClient
    let workspaceID: UUID
    @Environment(HostDirectory.self) private var hosts

    private var commands: [WireCommand]? { host.commands[workspaceID] }
    private var backgroundSessions: [WireBackgroundSession] { host.workspace(workspaceID)?.backgroundSessions ?? [] }
    private var workspaceRef: WorkspaceRef { WorkspaceRef(hostID: host.id, workspaceID: workspaceID) }

    var body: some View {
        List {
            ForEach(commands ?? []) { command in
                NavigationLink(value: Route.command(workspaceRef, commandID: command.id)) {
                    CommandRow(command: command) { host.toggle(command, in: workspaceID) }
                }
            }
            if !backgroundSessions.isEmpty {
                Section("Background") {
                    ForEach(backgroundSessions) { session in
                        NavigationLink(value: Route.backgroundSession(workspaceRef, sessionID: session.id)) {
                            BackgroundSessionRowiOS(session: session)
                        }
                        .contextMenu {
                            Button("Open Chat", systemImage: "bubble.left") {
                                hosts.pendingTask = TaskRef(hostID: host.id, taskID: session.taskID)
                            }
                        }
                    }
                }
            }
        }
        .contentMargins(.top, 10)
        .overlay {
            if commands == nil && backgroundSessions.isEmpty {
                ProgressView()
                    .controlSize(.large)
            } else if commands?.isEmpty == true && backgroundSessions.isEmpty {
                ContentUnavailableView(
                    "No Commands",
                    systemImage: "terminal",
                    description: Text("Add commands in the Commands inspector on \(host.name).")
                )
            }
        }
        .projectScopeTitle(host: host, workspaceID: workspaceID, placeholder: "Commands")
        .task(id: workspaceID) {
            await host.follow(.commands(workspaceID: workspaceID))
        }
    }
}

private struct BackgroundSessionRowiOS: View {
    let session: WireBackgroundSession

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(session.chatTitle)
                    .lineLimit(1)
                ProgressView()
            }
        } icon: {
            ProviderIcon(provider: session.provider)
        }
    }
}
