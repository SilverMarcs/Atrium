import AtriumProtocol
import SwiftUI

struct CommandRow: View {
    let command: WireCommand
    /// Runs the command, or stops it while it runs.
    let toggle: () -> Void

    var body: some View {
        LabeledContent {
            Button(command.isRunning ? "Stop" : "Run", systemImage: command.isRunning ? "stop.fill" : "play.fill", action: toggle)
            .labelStyle(.iconOnly)
            .foregroundStyle(command.isRunning ? .red : .accentColor)
            .contentTransition(.symbolEffect(.replace))
            .buttonStyle(.borderless)
            .disabled(!command.canRun && !command.isRunning)
        } label: {
            Label {
                HStack(spacing: 6) {
                    Text(command.title)
                        .lineLimit(1)
                    if command.isRunning {
                        ProgressView()
                    }
                }
                if let script = command.script, !script.isEmpty {
                    Text(script)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: command.isDefault ? "play.circle" : "apple.terminal")
            }
        }
    }
}
