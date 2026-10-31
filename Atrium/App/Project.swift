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
    /// The checkouts shown, shared with the host's other pages of the project.
    var scope: ProjectScope { host.scope(for: workspaceID) }
    var gitScope: GitScope { scope.gitScope }
    /// The project folder through its chosen checkout, where commands run.
    var root: URL { scope.root }
    /// What Files and Search show.
    var filesRoot: URL { scope.filesRoot }
    /// The project's repositories, once its host has sent their status.
    var repositories: [GitRepositoryStatus]? { scope.repositories }
    var commands: [WireCommand] { host.commands[workspaceID] ?? [] }
    var defaultCommand: WireCommand? { commands.first(where: \.isDefault) }
    /// Only a project on this Mac's own host can be edited and shows terminals.
    var isLocal: Bool { host.isLocal }

    /// The checkout holding a file, where Git runs for it: a worktree shown
    /// counts, so a file opened from it gets its own change markers.
    func checkout(containing url: URL) -> URL {
        (repositories ?? [])
            .map(\.repositoryRootURL)
            .filter { $0.contains(url) }
            .max { $0.pathComponents.count < $1.pathComponents.count } ?? root
    }

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

    /// Runs a command in the checkout shown, restarting it if it's running.
    func run(_ command: WireCommand) {
        send(.run(directory: root.filePath), to: command)
    }

    /// Stops a running command, or runs one that isn't.
    func toggle(_ command: WireCommand) {
        if command.isRunning { send(.stop, to: command) } else { run(command) }
    }

    /// Opens a file in the editor, showing the files tab with it selected.
    func reveal(_ url: URL) {
        scope.include(url)
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
