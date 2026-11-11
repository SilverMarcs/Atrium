import AtriumClient
import AtriumProtocol
import Foundation
import Observation

/// The files inspector: folders load from the host one level at a time as
/// they're expanded, and stay current while shown. Searching by name or
/// showing only changed files shows a tree of just those, built from the
/// host's matches and Git status.
@MainActor
@Observable
final class FileTreeModel {
    unowned let project: Project
    var selectedID: String?
    var pendingRevealID: String?
    var expandedIDs: Set<String> = []
    var savedExpandedIDs: Set<String>?
    var searchFocusTrigger = 0
    var renamingID: String?
    var searchText = ""
    var showChangedOnly = false
    private(set) var submittedSearchText = ""
    private(set) var isSearching = false
    private(set) var isTruncated = false
    /// Paths, relative to the root searched, of files whose names match.
    private var foundPaths: [String]?

    @ObservationIgnored private var findTask: Task<Void, Never>?
    @ObservationIgnored private var follows: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var statusCache: (repositories: [GitRepositoryStatus], statuses: [String: GitChangeKind])?

    init(project: Project) {
        self.project = project
    }

    var hasActiveFilter: Bool { !submittedSearchText.isEmpty || showChangedOnly }

    subscript(isExpanded id: String) -> Bool {
        get { expandedIDs.contains(id) }
        set { if newValue { expandedIDs.insert(id) } else { expandedIDs.remove(id) } }
    }

    /// The root and every expanded folder below it, which the host keeps current.
    var shownFolders: Set<String> {
        let root = project.filesRoot.filePath
        return Set(expandedIDs.filter { $0.hasPrefix(root + "/") }).union([root])
    }

    /// Follows exactly the folders shown, or none once the tree is hidden.
    func follow(_ folders: Set<String>) {
        for (path, task) in follows where !folders.contains(path) {
            task.cancel()
            follows[path] = nil
        }
        for path in folders where follows[path] == nil {
            let topic = HostTopic.directory(workspaceID: project.workspaceID, path: path)
            follows[path] = Task { [host = project.host] in await host.follow(topic) }
        }
    }

    /// A folder's entries once its host has sent them.
    func entries(in path: String) -> [FileEntry]? {
        project.host.directories[.directory(workspaceID: project.workspaceID, path: path)]
    }

    /// The tree a filter shows, or nil while browsing folders.
    var filteredNodes: [FileNode]? {
        guard hasActiveFilter else { return nil }
        let root = project.filesRoot.filePath
        var paths: Set<String>?
        if let foundPaths, !submittedSearchText.isEmpty {
            paths = Set(foundPaths.map { (root as NSString).appendingPathComponent($0) })
        }
        if showChangedOnly {
            let changed = Set((project.repositories ?? [])
                .flatMap { $0.unstagedFiles + $0.stagedFiles }
                .map { $0.fileURL.standardizedFileURL.filePath }
                .filter { $0.hasPrefix(root + "/") })
            paths = paths.map { $0.intersection(changed) } ?? changed
        }
        return FileNode.tree(of: paths ?? [], under: root)
    }

    /// A file's change, or for a folder the most important change inside it.
    func status(of path: String) -> GitChangeKind? {
        statuses[path]
    }

    /// Changes by path, with each folder taking its contents' most important change.
    private var statuses: [String: GitChangeKind] {
        let repositories = project.repositories ?? []
        if let statusCache, statusCache.repositories == repositories { return statusCache.statuses }
        var statuses: [String: GitChangeKind] = [:]
        for repository in repositories {
            for file in repository.unstagedFiles + repository.stagedFiles {
                var path = file.fileURL.standardizedFileURL.filePath
                statuses[path] = file.kind
                while true {
                    path = (path as NSString).deletingLastPathComponent
                    guard path.count > 1 else { break }
                    if let existing = statuses[path], existing.priority >= file.kind.priority { continue }
                    statuses[path] = file.kind
                }
            }
        }
        statusCache = (repositories, statuses)
        return statuses
    }

    func submitSearch() {
        submittedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        find()
    }

    /// Finds the submitted name again, below the folder now shown.
    func find() {
        findTask?.cancel()
        guard !submittedSearchText.isEmpty else {
            foundPaths = nil
            return
        }
        isSearching = true
        let query = submittedSearchText
        let root = project.filesRoot.filePath
        findTask = Task {
            defer { if !Task.isCancelled { isSearching = false } }
            guard case .found(let paths, let isTruncated) = try? await project.files(.find(root: root, query: query)),
                  !Task.isCancelled else { return }
            foundPaths = paths
            self.isTruncated = isTruncated
        }
    }

    func clearSearch() {
        findTask?.cancel()
        searchText = ""
        submittedSearchText = ""
        foundPaths = nil
        isSearching = false
        isTruncated = false
    }

    /// Expands the folders leading to a file and selects it once its row loads.
    func reveal(_ url: URL) {
        let root = project.filesRoot.filePath
        var parent = (url.filePath as NSString).deletingLastPathComponent
        while parent.hasPrefix(root), parent != root {
            expandedIDs.insert(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        pendingRevealID = url.filePath
    }

    // MARK: - Changes, on this Mac's own host only

    func create(in folder: String, isFolder: Bool) async {
        guard case .path(let path) = await perform(.create(inFolder: folder, isFolder: isFolder)) else { return }
        expandedIDs.insert(folder)
        selectedID = path
        renamingID = path
    }

    func rename(_ path: String, to name: String) async {
        renamingID = nil
        guard case .path(let renamed) = await perform(.rename(path: path, to: name)) else { return }
        selectedID = renamed
    }

    func duplicate(_ path: String) async {
        await perform(.duplicate(path: path))
    }

    func trash(_ path: String) async {
        await perform(.trash(path: path))
    }

    @discardableResult
    private func perform(_ request: FileRequest) async -> FileReply? {
        do {
            return try await project.files(request)
        } catch {
            project.host.actionError = error.localizedDescription
            return nil
        }
    }
}

/// A file or folder in a filtered tree; folders hold only what leads to matches.
struct FileNode: Identifiable, Hashable {
    let entry: FileEntry
    var children: [FileNode]?

    var id: String { entry.id }

    static func tree(of paths: Set<String>, under root: String) -> [FileNode] {
        var childPaths: [String: Set<String>] = [:]
        for path in paths {
            var child = path
            var parent = (path as NSString).deletingLastPathComponent
            while parent.count >= root.count {
                childPaths[parent, default: []].insert(child)
                guard parent != root else { break }
                child = parent
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        func nodes(in folder: String) -> [FileNode] {
            (childPaths[folder] ?? []).map { path in
                let isDirectory = childPaths[path] != nil
                let entry = FileEntry(name: (path as NSString).lastPathComponent, path: path, isDirectory: isDirectory)
                return FileNode(entry: entry, children: isDirectory ? nodes(in: path) : nil)
            }
            .sorted { FileEntry.precedes($0.entry, $1.entry) }
        }
        return nodes(in: root)
    }
}
