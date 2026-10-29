import AtriumClient
import AtriumProtocol
import Foundation
import Observation

/// A project open in the window, on whichever host it lives: its inspector
/// and editor state, and the checkouts it shows. Reads everything from its
/// host's client and changes things through requests.
@MainActor
@Observable
final class Project: Identifiable {
    let host: HostClient
    let workspaceID: UUID
    var selectedTab: InspectorTab = .files
    /// Main checkout → linked worktree shown instead, per repository. A
    /// repository with no entry is shown through its main checkout.
    var worktrees: [URL: URL] = [:]
    var selectedCommandID: UUID?
    let editor = EditorPanel()
    @ObservationIgnored private(set) lazy var fileTree = FileTreeModel(project: self)
    @ObservationIgnored private(set) lazy var search = SearchInspectorModel(project: self)
    @ObservationIgnored private(set) lazy var git = GitInspectorState(project: self)

    init(host: HostClient, workspaceID: UUID) {
        self.host = host
        self.workspaceID = workspaceID
    }

    var id: WorkspaceRef { WorkspaceRef(hostID: host.id, workspaceID: workspaceID) }
    var workspace: WireWorkspace? { host.workspace(workspaceID) }
    var path: String { workspace?.path ?? "" }
    var gitScope: GitScope { GitScope(workspaceID: workspaceID, worktrees: worktrees) }
    /// The folder files and search reflect: the worktree shown for the
    /// repository the project folder belongs to, if any.
    var root: URL { gitScope.root(of: path) }
    /// The project's repositories, once its host has sent their status.
    var repositories: [GitRepositoryStatus]? { host.gitStatuses[gitScope] }
    var commands: [WireCommand] { host.commands[workspaceID] ?? [] }
    var defaultCommand: WireCommand? { commands.first(where: \.isDefault) }
    /// Only a project on this Mac's own host can be edited and shows terminals.
    var isLocal: Bool { host.isLocal }

    func git(_ operation: GitOperation, in repository: URL) async throws -> GitReply {
        try await host.git(operation, in: repository, workspace: workspaceID)
    }

    func files(_ request: FileRequest) async throws -> FileReply {
        try await host.files(request, in: workspaceID)
    }

    func send(_ action: WorkspaceAction) {
        host.send(.workspace(id: workspaceID, action: action))
    }

    func send(_ action: CommandAction, to command: WireCommand) {
        host.send(.command(workspaceID: workspaceID, commandID: command.id, action: action))
    }

    /// Shows the checkout a task works in: the linked worktree it moved into,
    /// or its repository's main checkout. The user can move away from it.
    func showCheckout(_ checkout: TaskCheckout?) {
        guard let checkout, worktrees[checkout.repository] != checkout.worktree else { return }
        worktrees[checkout.repository] = checkout.worktree
        git.selectedRepoURL = checkout.repository
    }

    /// Opens a file in the editor, showing the files tab with it selected.
    func reveal(_ url: URL) {
        fileTree.reveal(url)
        selectedTab = .files
    }

    /// Opens a link from chat or a terminal when it names a file in the project.
    func openLink(_ link: String, from directory: String? = nil) async -> Bool {
        guard case .location(let path, let line) = try? await files(.resolveLink(link, directory: directory ?? root.path)) else {
            return false
        }
        editor.openFile(URL(filePath: path), scrollToLine: line)
        return true
    }
}
