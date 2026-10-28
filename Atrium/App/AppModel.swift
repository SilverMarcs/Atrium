import AppKit
import Observation
import SwiftUI

/// The Mac app: its own host, every host it's connected to, and what the
/// window shows. Nothing here touches projects, Git or files; that all goes
/// through a `HostClient`, including for this Mac's own host.
@MainActor
@Observable
final class AppModel {
    let hosts: HostDirectory
    /// This Mac's task and command terminals. They stay on its host, so only
    /// its own projects show them; nothing else of the host is reachable here.
    let terminals: HostTerminals
    /// The task the window shows, on whichever host it lives.
    var selection: TaskRef? {
        didSet {
            guard let selection, selection != oldValue, let task = hosts.task(selection),
                  let workspaceID = task.task.workspaceID else { return }
            // A task that moved into a worktree shows that worktree while staying in its project.
            project(WorkspaceRef(hostID: selection.hostID, workspaceID: workspaceID))?.showCheckout(task.task.checkout)
        }
    }
    var showingCompose = false
    var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    var showingInspector = true
    /// A running command the user asked to run again, awaiting confirmation.
    var pendingRunReplacement: (project: Project, command: WireCommand)?

    @ObservationIgnored private var projects: [WorkspaceRef: Project] = [:]
    @ObservationIgnored private var composers: [TaskRef: ComposerDraft] = [:]

    /// The app delegate reaches the app through this for notification taps.
    static private(set) weak var shared: AppModel?

    init() {
        let server = HostServer()
        terminals = server.terminals
        let localHost = HostClient(localID: server.hello.hostID, name: HostServer.hostName) {
            LoopbackConnection(server: server)
        }
        hosts = HostDirectory(localHost: localHost)
        hosts.start()
        Self.shared = self
        TerminalProcessCoordinator.shared.openFileLink = { [weak self] link, terminal in
            await self?.openLink(link, from: terminal) ?? false
        }
    }

    var localHost: HostClient? { hosts.localHost }
    var selectedTask: HostTask? { selection.flatMap(hosts.task) }

    /// The project of the task on screen, with its inspector and editor.
    var selectedProject: Project? {
        guard let task = selectedTask, let workspaceID = task.task.workspaceID else { return nil }
        return project(WorkspaceRef(hostID: task.host.id, workspaceID: workspaceID))
    }

    /// The terminal the window shows, for zooming it.
    var activeTerminal: Terminal? {
        guard let task = selectedTask, task.host.isLocal,
              let session = terminals.existingSession(for: task.task.id),
              session.isTerminalAttached, session.isTerminalVisible else { return nil }
        return session.terminal
    }

    func project(_ ref: WorkspaceRef) -> Project? {
        if let project = projects[ref] { return project }
        guard let host = hosts.host(ref.hostID) else { return nil }
        let project = Project(host: host, workspaceID: ref.workspaceID)
        projects[ref] = project
        return project
    }

    /// What's typed in a task's composer, kept per task while others are shown.
    func composer(for ref: TaskRef) -> ComposerDraft {
        if let composer = composers[ref] { return composer }
        let composer = ComposerDraft()
        composers[ref] = composer
        return composer
    }


    /// Opens a terminal link that names a file in the terminal's project.
    private func openLink(_ link: String, from terminal: Terminal) async -> Bool {
        guard let localHost, let workspaceID = terminal.workspace?.id,
              let project = project(WorkspaceRef(hostID: localHost.id, workspaceID: workspaceID)) else { return false }
        return await project.openLink(link, from: terminal.currentDirectory)
    }
}

/// A task's unsent prompt and images.
@MainActor
@Observable
final class ComposerDraft {
    var prompt = ""
    var images: [ComposerImage] = []
    var messageEdit: ConversationMessageEdit?

    /// Editing uses a separate draft, leaving the ordinary composer untouched.
    var inputText: String {
        get { messageEdit?.text ?? prompt }
        set {
            if let messageEdit { messageEdit.text = newValue }
            else { prompt = newValue }
        }
    }

    var inputImages: [ComposerImage] {
        get { messageEdit?.addedImages ?? images }
        set {
            if let messageEdit { messageEdit.addedImages = newValue }
            else { images = newValue }
        }
    }
}
