import AtriumProtocol
import SwiftUI

struct CommandEntryRow: View {
    let command: WireCommand
    let project: Project
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(command.title)
                        .font(.callout)
                        .lineLimit(1)
                    if command.isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 14, height: 14)
                    }
                }
                if let script = command.script, !script.isEmpty {
                    Text(script)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if command.isRunning || command.canRun {
                Button(command.isRunning ? "Stop" : "Run", systemImage: command.isRunning ? "stop.fill" : "play.fill") {
                    project.toggle(command)
                }
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 5)
        .contextMenu {
            if command.isRunning {
                Button("Stop", systemImage: "stop.fill") { project.send(.stop, to: command) }
            } else if command.canRun {
                Button("Run", systemImage: "play.fill") { project.run(command) }
            }
            Button("Clear", systemImage: "clear") { project.send(.clear, to: command) }
            Divider()
            Button("Set Default Command", systemImage: command.isDefault ? "checkmark" : "play.circle") {
                project.send(.setDefault, to: command)
            }
            .disabled(command.isDefault || !command.canRun)
            Button("Edit", systemImage: "pencil", action: edit)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { project.send(.remove, to: command) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !command.canRun {
                Button("Delete", systemImage: "trash", role: .destructive) { project.send(.remove, to: command) }
                    .labelStyle(.iconOnly)
            }
        }
    }
}
