import Foundation

/// The terminals tasks and saved commands run in. They stay on the host, so
/// only the Mac's own UI shows them; every other client gets commands' state
/// and run and stop through requests.
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
