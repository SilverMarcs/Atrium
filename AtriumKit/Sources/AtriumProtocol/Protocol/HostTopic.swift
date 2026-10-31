import Foundation

/// State a client wants pushed to it. Subscribing sends the current state;
/// the host then sends changes until the client unsubscribes or disconnects.
public nonisolated enum HostTopic: Codable, Sendable, Hashable {
    case tasks
    /// A task's conversation.
    case transcript(taskID: String)
    case terminal(taskID: String)
    case git(GitScope)
    case commands(workspaceID: UUID)
    /// One folder's entries, watched on the host.
    case directory(workspaceID: UUID, path: String)
    /// Changes to one file, watched on the host.
    case file(workspaceID: UUID, path: String)
    /// The host's remote access and paired devices, for its own Mac only.
    case remoteAccess
    /// A topic this host doesn't know, from a newer client.
    case unknown

    private enum CodingKeys: String, CodingKey {
        case kind, taskID, scope, workspaceID, path
    }

    private enum Kind: String, Codable {
        case tasks, transcript, terminal, git, commands, directory, file, remoteAccess
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let kind = try? container.decode(Kind.self, forKey: .kind) else {
            self = .unknown
            return
        }
        switch kind {
        case .tasks: self = .tasks
        case .remoteAccess: self = .remoteAccess
        case .transcript: self = .transcript(taskID: try container.decode(String.self, forKey: .taskID))
        case .terminal: self = .terminal(taskID: try container.decode(String.self, forKey: .taskID))
        case .git: self = .git(try container.decode(GitScope.self, forKey: .scope))
        case .commands: self = .commands(workspaceID: try container.decode(UUID.self, forKey: .workspaceID))
        case .directory, .file:
            let workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
            let path = try container.decode(String.self, forKey: .path)
            self = kind == .file ? .file(workspaceID: workspaceID, path: path) : .directory(workspaceID: workspaceID, path: path)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tasks:
            try container.encode(Kind.tasks, forKey: .kind)
        case .remoteAccess:
            try container.encode(Kind.remoteAccess, forKey: .kind)
        case .transcript(let taskID):
            try container.encode(Kind.transcript, forKey: .kind)
            try container.encode(taskID, forKey: .taskID)
        case .terminal(let taskID):
            try container.encode(Kind.terminal, forKey: .kind)
            try container.encode(taskID, forKey: .taskID)
        case .git(let scope):
            try container.encode(Kind.git, forKey: .kind)
            try container.encode(scope, forKey: .scope)
        case .commands(let workspaceID):
            try container.encode(Kind.commands, forKey: .kind)
            try container.encode(workspaceID, forKey: .workspaceID)
        case .directory(let workspaceID, let path), .file(let workspaceID, let path):
            try container.encode(self.isFile ? Kind.file : Kind.directory, forKey: .kind)
            try container.encode(workspaceID, forKey: .workspaceID)
            try container.encode(path, forKey: .path)
        case .unknown:
            try container.encode("unknown", forKey: .kind)
        }
    }

    private var isFile: Bool {
        if case .file = self { true } else { false }
    }
}

/// Which checkouts a project's Git status covers: each repository in the
/// project, seen through the linked worktree a client chose for it, if any.
public nonisolated struct GitScope: Codable, Sendable, Hashable {
    public var workspaceID: UUID
    /// Main checkout root → linked worktree root.
    public var worktrees: [URL: URL] = [:]

    public init(workspaceID: UUID, worktrees: [URL: URL] = [:]) {
        self.workspaceID = workspaceID
        self.worktrees = worktrees
    }

    /// The project folder seen through the worktree chosen for the repository
    /// that contains it, if any: the same folder inside that worktree.
    public func root(of workspacePath: String) -> URL {
        let folder = URL(filePath: workspacePath, directoryHint: .isDirectory)
        for (repository, worktree) in worktrees where repository.contains(folder) {
            let inside = folder.standardizedFileURL.pathComponents.dropFirst(repository.standardizedFileURL.pathComponents.count)
            return inside.reduce(worktree) { $0.appending(path: $1, directoryHint: .isDirectory) }
        }
        return folder
    }
}

public nonisolated extension URL {
    /// The path as hosts and clients spell it: without percent encoding or a
    /// trailing slash, so a folder's path is the same however its URL was made.
    var filePath: String {
        let path = path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Whether this folder is `url` or one of its ancestors, by path alone.
    func contains(_ url: URL) -> Bool {
        let parent = standardizedFileURL.pathComponents
        let child = url.standardizedFileURL.pathComponents
        return child.count >= parent.count && zip(parent, child).allSatisfy(==)
    }
}
