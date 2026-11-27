import AppKit
import Observation

/// A project open in the window, on whichever host it lives: its inspector
/// and editor state, and the checkouts it shows. Reads everything from its
/// host's client and changes things through requests.
@MainActor
@Observable
final class Project: Identifiable {
    enum CommandSelection: Hashable {
        case background(String)
        case command(UUID)
    }

    let host: HostClient
    let workspaceID: UUID
    var opensCommandInspectorOnSelection = false
    var selectedCommand: CommandSelection?
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
    var backgroundSessions: [WireBackgroundSession] { workspace?.backgroundSessions ?? [] }
    /// Saved commands and agent background sessions running, for the Commands tab's badge.
    var runningCount: Int { workspace?.runningCount ?? 0 }
    var defaultCommand: WireCommand? { commands.first(where: \.isDefault) }
    /// Only a project on this Mac's own host can be edited.
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
        host.run(command.id, in: workspaceID)
    }

    func console(for command: WireCommand) -> CommandConsole {
        .of(command.id, in: workspaceID, on: host)
    }

    /// Stops a running command, or runs one that isn't.
    func toggle(_ command: WireCommand) {
        host.toggle(command, in: workspaceID)
    }

    /// Selects a file in the file tree, which the caller then shows.
    func reveal(_ url: URL) {
        scope.include(url)
        fileTree.reveal(url)
    }

    /// Opens a link from chat or command output: a web page or HTML file in
    /// `browse`, the chat's browser, when there is one, and otherwise web pages
    /// in the system's browser; other files in the project in its editor, and
    /// elsewhere on this Mac in Finder. Relative paths resolve from
    /// `directory`, or the project folder.
    func openLink(_ link: String, from directory: String? = nil, browse: ((URL) -> Void)? = nil) {
        if let url = URL(string: link), url.isWebPage {
            if let browse { browse(url) } else { NSWorkspace.shared.open(url) }
            return
        }
        let directory = directory.flatMap { $0.isEmpty ? nil : $0 } ?? root.filePath
        Task {
            let location: (path: String, line: Int?)?
            let isInProject: Bool
            if case .location(let path, let line) = try? await files(.resolveLink(link, directory: directory)) {
                (location, isInProject) = ((path, line), true)
            } else {
                (location, isInProject) = (isLocal ? FileService.resolve(link, relativeTo: [directory], access: nil) : nil, false)
            }
            guard let location else {
                // Not a file, such as a mail address, which goes to its default app.
                if isLocal, let url = URL(string: link), url.scheme != nil { NSWorkspace.shared.open(url) }
                return
            }
            let file = URL(filePath: location.path)
            // A link to a line in a page is to its source.
            if let browse, location.line == nil, file.isHTMLFile {
                browse(file)
            } else if isInProject {
                editor.openFile(file, scrollToLine: location.line)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        }
    }
}

extension URL {
    /// A page the chat's browser opens rather than the system's.
    var isWebPage: Bool { ["http", "https"].contains(scheme?.lowercased() ?? "") }

    var isHTMLFile: Bool { ["html", "htm", "xhtml"].contains(pathExtension.lowercased()) }
}
