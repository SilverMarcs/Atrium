import SwiftUI

/// Lists the saved commands for one workspace and lets the user run or stop
/// each. No terminal output here — the iOS surface is intentionally a tiny
/// remote control for the host's commands inspector.
struct CommandsScreen: View {
    @Environment(CompanionClient.self) private var client
    let workspaceId: UUID

    var body: some View {
        Group {
            if client.commands.isEmpty {
                ContentUnavailableView(
                    "No Commands",
                    systemImage: "terminal",
                    description: Text("Add commands from the host app to run them here.")
                )
            } else {
                List(client.commands) { command in
                    CommandRow(workspaceId: workspaceId, command: command)
                }
                .contentMargins(.top, 10)
            }
        }
        .navigationTitle("Commands")
        .toolbarTitleDisplayMode(.inline)
        .task(id: workspaceId) {
            client.commandsSubscribe(workspaceId: workspaceId)
        }
    }
}

private struct CommandRow: View {
    @Environment(CompanionClient.self) private var client
    let workspaceId: UUID
    let command: WireCommand

    private var hasScript: Bool {
        !(command.script?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    var body: some View {
        LabeledContent {
            actionButton
        } label: {
            Label {
                Text(command.title)
                    .lineLimit(1)
                if let script = command.script, !script.isEmpty {
                    Text(script)
                        .lineLimit(1)
                }
            } icon: {
                if command.isRunning {
                    ProgressView()
                } else {
                    Image(systemName: "apple.terminal")
                }
            }
        }
    }

    var actionButton: some View {
        Button(action: buttonAction) {
            Image(systemName: isRunning ? "stop.fill" : "play.fill")
                .foregroundStyle(isRunning ? .red : .accentColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .disabled(!hasScript && !isRunning)
    }

    private var isRunning: Bool { command.isRunning }

    private func buttonAction() {
        if isRunning {
            client.stopCommand(workspaceId: workspaceId, commandId: command.id)
        } else {
            client.runCommand(workspaceId: workspaceId, commandId: command.id)
        }
    }
}
