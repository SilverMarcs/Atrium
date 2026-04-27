import AppKit
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    var id: String { url.path }
    let name: String
    let url: URL
    let isDirectory: Bool
    var children: [FileItem]?
    var gitStatus: GitChangeKind?

    var isHidden: Bool {
        name.hasPrefix(".")
    }

    var icon: NSImage {
        url.fileIcon
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url && lhs.gitStatus == rhs.gitStatus && lhs.children == rhs.children
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    /// Returns a filtered copy of the tree.
    func filtered(searchText: String, changedURLs: Set<URL>?, showChangedOnly: Bool) -> FileItem? {
        if !isDirectory {
            let nameMatch = searchText.isEmpty || name.localizedCaseInsensitiveContains(searchText)
            let gitMatch = !showChangedOnly || changedURLs?.contains(url.standardizedFileURL) == true
            return (nameMatch && gitMatch) ? self : nil
        }

        let filteredChildren = children?.compactMap {
            $0.filtered(searchText: searchText, changedURLs: changedURLs, showChangedOnly: showChangedOnly)
        }

        guard let filteredChildren, !filteredChildren.isEmpty else { return nil }

        var copy = self
        copy.children = filteredChildren
        return copy
    }

    /// Clears git statuses from this item and all descendants.
    mutating func clearGitStatuses() {
        gitStatus = nil
        if var kids = children {
            for i in kids.indices { kids[i].clearGitStatuses() }
            children = kids
        }
    }

    /// Applies git statuses to this item and all descendants.
    /// Directories bubble up the highest-priority status from their children.
    mutating func applyGitStatuses(_ statuses: [URL: GitChangeKind]) {
        let resolved = url.standardizedFileURL
        if let status = statuses[resolved] {
            gitStatus = status
        }

        if var kids = children {
            for i in kids.indices {
                kids[i].applyGitStatuses(statuses)
            }
            children = kids

            // Bubble up: take the highest-priority child status
            if gitStatus == nil {
                let childStatuses = kids.compactMap(\.gitStatus)
                gitStatus = childStatuses.max(by: { $0.priority < $1.priority })
            }
        }
    }

    static func buildTree(at directoryURL: URL, showHiddenFiles: Bool = false, maxDepth: Int = 15) -> [FileItem] {
        buildTree(at: directoryURL, showHiddenFiles: showHiddenFiles, maxDepth: maxDepth, currentDepth: 0)
    }

    private static func buildTree(at directoryURL: URL, showHiddenFiles: Bool, maxDepth: Int, currentDepth: Int) -> [FileItem] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: showHiddenFiles ? [] : [.skipsHiddenFiles]
        ) else { return [] }

        let atDepthLimit = currentDepth + 1 >= maxDepth

        return contents
            .filter { !ignoredNames.contains($0.lastPathComponent) }
            .compactMap { url -> FileItem? in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                let isDir = values?.isDirectory ?? false
                let children: [FileItem]? = isDir
                    ? (atDepthLimit ? nil : buildTree(at: url, showHiddenFiles: showHiddenFiles, maxDepth: maxDepth, currentDepth: currentDepth + 1))
                    : nil
                return FileItem(
                    name: url.lastPathComponent,
                    url: url,
                    isDirectory: isDir,
                    children: children
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    static let ignoredNames: Set<String> = [
        ".DS_Store", ".git", "node_modules", ".build", "DerivedData",
        "Pods", "__pycache__", ".venv", "venv", ".svn", ".hg",
    ]
}


extension URL {
    /// Returns the path of this URL relative to the given directory, or the last path component if not nested.
    func relativePath(from directoryURL: URL) -> String {
        let filePath = self.standardizedFileURL.path(percentEncoded: false)
        var dirPath = directoryURL.standardizedFileURL.path(percentEncoded: false)
        if !dirPath.hasSuffix("/") { dirPath += "/" }
        if filePath.hasPrefix(dirPath) {
            return String(filePath.dropFirst(dirPath.count))
        }
        return lastPathComponent
    }

    var fileIcon: NSImage {
        let values = try? resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true {
            return NSWorkspace.shared.icon(for: .folder)
        }
        let type = UTType(filenameExtension: pathExtension.lowercased()) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

extension GitChangeKind {

    /// Higher = more important. Used to pick the dominant status for folders.
    var priority: Int {
        switch self {
            case .typeChanged: 0
            case .copied: 1
            case .renamed: 2
            case .modified: 3
            case .added, .untracked: 4
            case .deleted: 5
            case .conflicted: 6
        }
    }
}
