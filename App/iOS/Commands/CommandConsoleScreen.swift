import AtriumClient
import AtriumProtocol
import SwiftUI

/// One of a project's saved commands on its host: what it printed, with
/// replies, keys and one-off scripts typed below.
struct CommandConsoleScreen: View {
    @State private var console: CommandConsole

    init(host: HostClient, workspaceID: UUID, commandID: UUID) {
        _console = State(initialValue: .of(commandID, in: workspaceID, on: host))
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let command {
                    CommandInputBar(command: command, console: console)
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
                                console.host.toggle(command, in: console.workspaceID)
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
