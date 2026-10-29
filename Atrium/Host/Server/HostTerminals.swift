import Foundation

/// Direct access to this Mac's task and saved-command terminals. Remote task
/// viewers use the terminal topic; commands still expose only run/stop state.
@MainActor
struct HostTerminals {
    let sessions: TaskSessionController
    let workspaces: WorkspaceStore

    var isOpening: Bool { sessions.isOpening }

    /// The task's terminal session, ready to attach.
    func session(for taskID: String) -> TaskSession? {
        sessions.session(for: taskID)
    }

    func attachTerminal(to session: TaskSession) async {
        await sessions.attachTerminal(to: session)
    }

    /// The task's terminal session, if it has one already.
    func existingSession(for taskID: String) -> TaskSession? {
        sessions.sessions[taskID]
    }

    /// A saved command's terminal.
    func command(_ id: UUID, in workspaceID: UUID) -> Terminal? {
        workspaces.workspaces.first { $0.id == workspaceID }?.commands.first { $0.id == id }
    }
}
