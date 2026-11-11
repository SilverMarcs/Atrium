import AtriumClient
import AtriumProtocol
import Foundation
import Observation

/// Typing into one of a project's saved commands, on whichever host it's on:
/// a reply while it runs, or a one-off script in the checkout the project shows
/// while it doesn't. One-off scripts can be recalled; replies aren't kept, as
/// they may be passwords. Each command has one, kept while other pages show.
@MainActor
@Observable
final class CommandConsole {
    let host: HostClient
    let workspaceID: UUID
    let commandID: UUID
    var draft = ""
    private var history: [String] = []
    /// The history entry shown in place of the draft, while recalling.
    private var recalled: Int?
    private var draftBeforeRecall = ""
    private static var consoles: [UUID: CommandConsole] = [:]

    private init(host: HostClient, workspaceID: UUID, commandID: UUID) {
        self.host = host
        self.workspaceID = workspaceID
        self.commandID = commandID
    }

    /// The console of a command, with what was typed and run in it so far.
    static func of(_ commandID: UUID, in workspaceID: UUID, on host: HostClient) -> CommandConsole {
        if let console = consoles[commandID] { return console }
        let console = CommandConsole(host: host, workspaceID: workspaceID, commandID: commandID)
        consoles[commandID] = console
        return console
    }

    var command: WireCommand? { host.commands[workspaceID]?.first { $0.id == commandID } }
    var output: WireCommandOutput? { host.commandOutputs[commandID] }
    var topic: HostTopic { .commandOutput(workspaceID: workspaceID, commandID: commandID) }
    /// Where a run starts: the project folder in the checkout the project shows.
    var directory: String { host.scope(for: workspaceID).root.filePath }

    func submit() {
        guard let command else { return }
        if command.isRunning {
            perform(.input(draft))
            draft = ""
            return
        }
        let script = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return }
        if history.last != script { history.append(script) }
        recalled = nil
        draft = ""
        host.run(commandID, in: workspaceID, script: script)
    }

    func perform(_ action: CommandAction) {
        host.send(.command(workspaceID: workspaceID, commandID: commandID, action: action))
    }

    /// Shows the previous one-off script in place of the draft.
    func recallPrevious() {
        guard !history.isEmpty else { return }
        if recalled == nil { draftBeforeRecall = draft }
        let index = max((recalled ?? history.count) - 1, 0)
        recalled = index
        draft = history[index]
    }

    /// Shows the next one-off script, or the draft after the last one.
    func recallNext() {
        guard let index = recalled else { return }
        if index + 1 < history.count {
            recalled = index + 1
            draft = history[index + 1]
        } else {
            recalled = nil
            draft = draftBeforeRecall
        }
    }
}
