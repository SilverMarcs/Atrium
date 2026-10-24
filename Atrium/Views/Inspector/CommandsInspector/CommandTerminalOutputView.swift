import SwiftUI

struct CommandTerminalOutputView: View {
    let terminal: Terminal
    @Environment(AppState.self) private var appState

    private let barHeight: CGFloat = 26

    private var hasScript: Bool {
        !(terminal.runScript?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(terminal.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 6) {
                    Button { terminal.clearTerminal() } label: {
                        Image(systemName: "delete.left")
                            .font(.caption2)
                    }
                    .help("Reset terminal")
                    .frame(width: barHeight, height: barHeight)
                    .background(.secondary.opacity(0.15), in: Circle())

                    if terminal.isRunning || hasScript {
                        Button {
                            if terminal.isRunning {
                                terminal.stop()
                            } else {
                                terminal.workspace?.runCommand(terminal)
                            }
                        } label: {
                            Image(systemName: terminal.isRunning ? "stop.fill" : "play.fill")
                                .font(.caption2)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .help(terminal.isRunning ? "Stop" : "Run")
                        .frame(width: barHeight, height: barHeight)
                        .background(.secondary.opacity(0.15), in: Circle())
                    }
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.top, 5)
            // .frame(height: 36)

            TerminalContainerRepresentable(terminal: terminal, appState: appState)
        }
    }
}
