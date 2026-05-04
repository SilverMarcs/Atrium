import SwiftUI

struct CommandEntryRow: View {
    let command: Command

    @State private var showEditSheet = false

    private var isRunning: Bool { command.isRunning }
    private var hasScript: Bool {
        !(command.runScript?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(command.title)
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
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !hasScript {
                Button(role: .destructive) {
                    command.workspace?.removeCommand(command)
                } label: {
                    Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let workspace = command.workspace {
                CommandEntrySheet(workspace: workspace, terminal: command)
            }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let script = command.runScript, !script.isEmpty {
            Text(script)
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
        if isRunning || hasScript {
            Button {
                if isRunning {
                    command.interrupt()
                } else {
                    command.workspace?.runCommand(command)
                }
            } label: {
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .animation(.default, value: isRunning)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if isRunning {
            Button { command.interrupt() } label: {
                Label("Interrupt", systemImage: "stop.fill")
            }
        } else if hasScript {
            Button {
                command.workspace?.runCommand(command)
            } label: {
                Label("Run", systemImage: "play.fill")
            }
        }

        if hasScript {
            Button {
                runInExternalTerminal()
            } label: {
                Label("Run in Terminal", systemImage: "terminal")
            }
        }

        Divider()

        Button {
            command.workspace?.setDefaultCommand(command)
        } label: {
            Label("Set Default Command", systemImage: command.isDefault ? "checkmark" : "play.circle")
        }
        .disabled(command.isDefault || !hasScript)

        Button {
            showEditSheet = true
        } label: {
            Label("Edit", systemImage: "pencil")
        }

        Divider()

        Button {
            command.clearOutput()
        } label: {
            Label("Clear", systemImage: "clear")
        }

        Button(role: .destructive) {
            command.terminate()
        } label: {
            Label("Kill", systemImage: "xmark.octagon")
        }
        .disabled(!isRunning)

        Button(role: .destructive) {
            command.workspace?.removeCommand(command)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Writes the saved script to a tempfile as a `.command` and hands it to
    /// the user's default handler (Terminal.app out of the box, iTerm/etc. if
    /// they've reassigned). Sidesteps AppleScript and quote-escaping by
    /// letting the shebang + a real file do the work.
    private func runInExternalTerminal() {
        guard let script = command.runScript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty else { return }
        let dir = command.workspace?.directory ?? ""
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("atrium-\(UUID().uuidString).command")
        var body = "#!/bin/zsh -l\n"
        if !dir.isEmpty {
            body += "cd '\(dir.replacingOccurrences(of: "'", with: "'\\''"))'\n"
        }
        body += script + "\n"
        do {
            try body.write(to: tmp, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            NSWorkspace.shared.open(tmp)
        } catch {
            command.output.append("[failed to launch external terminal: \(error.localizedDescription)]\n")
        }
    }
}
