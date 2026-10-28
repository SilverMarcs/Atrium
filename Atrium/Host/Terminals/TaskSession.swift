import Foundation
import Observation

/// A task's terminal on its host: the agent's CLI, attached on demand to the
/// same conversation the chat shows.
@MainActor
@Observable
final class TaskSession: Identifiable {
    let id: String
    var thread: AgentThread
    let workspace: Workspace
    private(set) var terminal: Terminal
    var isTerminalAttached = false
    var isTerminalVisible = false
    var isAttachingTerminal = false
    var terminalError: String?

    init(thread: AgentThread, workspace: Workspace, launch: AgentLaunch? = nil) {
        id = thread.id
        self.thread = thread
        self.workspace = workspace
        terminal = Terminal(workspace: workspace, title: thread.title, currentDirectory: thread.directory, isTaskTerminal: true)
        terminal.pendingLaunch = launch
    }

    func restart(launch: AgentLaunch) {
        terminal.terminate()
        terminal = Terminal(workspace: workspace, title: thread.title, currentDirectory: thread.directory, isTaskTerminal: true)
        terminal.pendingLaunch = launch
        isTerminalAttached = false
    }
}
