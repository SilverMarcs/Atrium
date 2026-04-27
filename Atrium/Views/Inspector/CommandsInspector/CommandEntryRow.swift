import SwiftUI
import SwiftTerm

struct CommandEntryRow: View {
    let terminal: Terminal

    @State private var showEditSheet = false

    private var isRunning: Bool { terminal.hasChildProcess }
    private var hasScript: Bool {
        !(terminal.runScript?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(terminal.title)
                        .font(.callout)
                        .lineLimit(1)
                    statusIndicator
                }

                subtitle
            }

            Spacer()

            actionButton
        }
        .padding(.horizontal, 5)
        .contextMenu {
            contextMenuItems
        }
        .sheet(isPresented: $showEditSheet) {
            if let workspace = terminal.workspace {
                CommandEntrySheet(workspace: workspace, terminal: terminal)
            }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let script = terminal.runScript, !script.isEmpty {
            Text(script)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else if !terminal.displayDirectory.isEmpty {
            Text(terminal.displayDirectory)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isRunning {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isRunning {
            Button {
                terminal.interrupt()
            } label: {
                Image(systemName: "stop.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
        } else if hasScript {
            Button {
                terminal.workspace?.runCommand(terminal)
            } label: {
                Image(systemName: "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if isRunning {
            Button { terminal.interrupt() } label: {
                Label("Interrupt", systemImage: "stop.fill")
            }
        } else if hasScript {
            Button {
                terminal.workspace?.runCommand(terminal)
            } label: {
                Label("Run", systemImage: "play.fill")
            }
        }

        Button {
            terminal.clearTerminal()
        } label: {
            Label("Clear", systemImage: "clear")
        }
        .disabled(terminal.localProcessTerminalView == nil)

        Divider()

        Button {
            terminal.workspace?.setDefaultCommand(terminal)
        } label: {
            Label("Set Default Command", systemImage: terminal.isDefault ? "checkmark" : "play.circle")
        }
        .disabled(terminal.isDefault || !hasScript)

        Button {
            showEditSheet = true
        } label: {
            Label("Edit", systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            terminal.terminate()
        } label: {
            Label("Kill", systemImage: "xmark.octagon")
        }
        .disabled(terminal.localProcessTerminalView == nil)

        Button(role: .destructive) {
            terminal.workspace?.removeCommand(terminal)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}
