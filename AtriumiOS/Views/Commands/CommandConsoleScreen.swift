import AtriumClient
import AtriumProtocol
import SwiftUI

/// One of a project's saved commands on its host: what it printed, with
/// replies, keys and one-off scripts typed below.
struct CommandConsoleScreen: View {
    @State private var console: CommandConsole

    init(host: HostClient, workspaceID: UUID, commandID: UUID) {
        _console = State(initialValue: CommandConsole(host: host, workspaceID: workspaceID, commandID: commandID))
    }

    private var command: WireCommand? { console.command }

    var body: some View {
        CommandOutputLines(output: console.output)
            .overlay {
                if console.host.commands[console.workspaceID] != nil, command == nil {
                    ContentUnavailableView("Command Removed", systemImage: "terminal",
                                           description: Text("This command is no longer in the project."))
                }
            }
            .safeAreaBar(edge: .bottom) {
                if let command {
                    CommandReplyBar(command: command, console: console)
                }
            }
            .navigationTitle(command?.title ?? "Command")
            .navigationSubtitle(command?.status ?? "")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                if let command {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear Output", systemImage: "clear") { console.perform(.clear) }
                    }
                    if command.isRunning || command.canRun {
                        ToolbarItem(placement: .primaryAction) {
                            Button(command.isRunning ? "Stop" : "Run", systemImage: command.isRunning ? "stop.fill" : "play.fill") {
                                if command.isRunning { console.perform(.stop) } else { console.host.run(command.id, in: console.workspaceID) }
                            }
                            .contentTransition(.symbolEffect(.replace))
                        }
                    }
                }
            }
            .task(id: console.workspaceID) { await console.host.follow(.commands(workspaceID: console.workspaceID)) }
            .task(id: console.topic) { await console.host.follow(console.topic) }
    }
}

/// Output lines, numbered as the host numbers them so only new ones lay out,
/// following the end as more arrive.
private struct CommandOutputLines: View {
    let output: WireCommandOutput?

    var body: some View {
        ScrollView {
            if let output {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(output.firstLine..<output.end, id: \.self) { number in
                        let line = output.lines[number - output.firstLine]
                        Text(line.isEmpty ? " " : line)
                    }
                }
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .overlay {
            if output == nil {
                ProgressView()
                    .controlSize(.large)
            }
        }
    }
}

/// Types a reply while the command runs, with keys for prompts that want
/// more, or a one-off script in the project's checkout while it doesn't.
private struct CommandReplyBar: View {
    let command: WireCommand
    @Bindable var console: CommandConsole
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            TextField(command.isRunning ? "Reply" : "Run a command", text: $console.draft)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(command.isRunning ? .send : .go)
                .focused($isFocused)
                .onSubmit {
                    console.submit()
                    isFocused = true
                }
            if command.isRunning {
                CommandKeysMenu { console.perform(.key($0)) }
                    .labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .glassEffect(in: .capsule)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
