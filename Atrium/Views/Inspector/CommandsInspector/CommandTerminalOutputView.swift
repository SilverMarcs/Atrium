import AtriumProtocol
import SwiftUI

/// A command's terminal on this Mac's own host.
struct CommandTerminalOutputView: View {
    let command: WireCommand
    let terminal: Terminal
    let project: Project

    private let barHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(command.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 6) {
                    Button("Reset Terminal", systemImage: "delete.left") { terminal.clearTerminal() }
                        .labelStyle(.iconOnly)
                        .font(.caption2)
                        .help("Reset terminal")
                        .frame(width: barHeight, height: barHeight)
                        .background(.secondary.opacity(0.15), in: .circle)

                    if command.isRunning || command.canRun {
                        Button(command.isRunning ? "Stop" : "Run", systemImage: command.isRunning ? "stop.fill" : "play.fill") {
                            project.send(command.isRunning ? .stop : .run, to: command)
                        }
                        .labelStyle(.iconOnly)
                        .font(.caption2)
                        .contentTransition(.symbolEffect(.replace))
                        .help(command.isRunning ? "Stop" : "Run")
                        .frame(width: barHeight, height: barHeight)
                        .background(.secondary.opacity(0.15), in: .circle)
                    }
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.top, 5)

            TerminalContainerRepresentable(terminal: terminal)
        }
    }
}
