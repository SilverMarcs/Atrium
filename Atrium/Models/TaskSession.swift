import Foundation
import Observation

@MainActor
@Observable
final class TaskSession: Identifiable {
    let id: String
    let conversation = ConversationStore()
    var chatPrompt = ""
    var chatImages: [ComposerImage] = []
    var thread: AgentThread
    let workspace: Workspace
    private(set) var terminal: Terminal

    init(thread: AgentThread, workspace: Workspace, launch: AgentLaunch) {
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
    }
}
