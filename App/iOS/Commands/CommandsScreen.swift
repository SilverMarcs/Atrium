import AtriumClient
import AtriumProtocol
import SwiftUI

/// The project's saved commands on its host. Each runs there in the checkout
/// the project's other pages show, and opens to its output and input.
struct CommandsScreen: View {
    let host: HostClient
    let workspaceID: UUID

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
        LabeledContent {
            ProgressView()
        } label: {
            Label {
                Text(session.title)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .lineLimit(1)
                }
            } icon: {
                ProviderIcon(provider: session.provider)
            }
        }
    }

    private var subtitle: String? {
        let trimmed = session.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != session.title {
            return trimmed
        }
        return session.taskTitle.isEmpty ? session.provider.name : "\(session.provider.name) · \(session.taskTitle)"
    }
}
