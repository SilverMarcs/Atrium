import SwiftUI

struct CommandRow: View {
    @Environment(CompanionClient.self) private var client
    let workspaceID: UUID
    let command: WireCommand

    var body: some View {
        LabeledContent {
            Button(command.isRunning ? "Stop" : "Run", systemImage: command.isRunning ? "stop.fill" : "play.fill") {
                client.send(.command(workspaceID: workspaceID, commandID: command.id, action: command.isRunning ? .stop : .run))
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(command.isRunning ? .red : .accentColor)
            .contentTransition(.symbolEffect(.replace))
            .buttonStyle(.borderless)
            .disabled(!command.canRun && !command.isRunning)
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
                    Image(systemName: command.isDefault ? "play.circle" : "apple.terminal")
                }
            }
        }
    }
}
