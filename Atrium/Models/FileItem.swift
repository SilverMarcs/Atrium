import AppKit
import UniformTypeIdentifiers

nonisolated struct FileItem: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let name: String
    let url: URL
    let isDirectory: Bool
    var children: [FileItem]?
    var gitStatus: GitChangeKind?

    var isHidden: Bool {
        name.hasPrefix(".")
    }

    @MainActor var icon: NSImage {
        url.fileIcon
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url && lhs.gitStatus == rhs.gitStatus && lhs.children == rhs.children
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    /// Returns a filtered copy of the tree.
    func filtered(searchText: String, changedURLs: Set<URL>?, showChangedOnly: Bool) throws -> FileItem? {
        try Task.checkCancellation()
        if !isDirectory {
            let nameMatch = searchText.isEmpty || name.localizedStandardContains(searchText)
            let gitMatch = !showChangedOnly || changedURLs?.contains(url.standardizedFileURL) == true
            return (nameMatch && gitMatch) ? self : nil
        }

        let filteredChildren = try children?.compactMap {
            try $0.filtered(searchText: searchText, changedURLs: changedURLs, showChangedOnly: showChangedOnly)
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

    /// Explicitly leaves the main actor, even when called by a UI-owned task.
    /// Limit the entire tree, rather than just its depth, to bound memory use.
    @concurrent
    static func buildTree(
        at directoryURL: URL,
        showHiddenFiles: Bool = false,
        maxDepth: Int = 15,
        maxItems: Int = 100_000
    ) async throws -> (items: [FileItem], isTruncated: Bool) {
        var remainingItems = maxItems
        var isTruncated = false
        let items = try buildTree(
            at: directoryURL, showHiddenFiles: showHiddenFiles, maxDepth: maxDepth,
            currentDepth: 0, remainingItems: &remainingItems, isTruncated: &isTruncated
        )
        return (items, isTruncated)
    }

    @concurrent
    static func filter(
        _ items: [FileItem], searchText: String, changedURLs: Set<URL>, showChangedOnly: Bool
    ) async throws -> [FileItem] {
        try items.compactMap {
            try $0.filtered(searchText: searchText, changedURLs: changedURLs, showChangedOnly: showChangedOnly)
        }
    }

    private static func buildTree(
        at directoryURL: URL, showHiddenFiles: Bool, maxDepth: Int, currentDepth: Int,
        remainingItems: inout Int, isTruncated: inout Bool
    ) throws -> [FileItem] {
        try Task.checkCancellation()
        // Enumerate one directory at a time so a huge folder cannot allocate an
        // unbounded URL array before the tree's item limit is checked.
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !showHiddenFiles { options.insert(.skipsHiddenFiles) }
        guard let contents = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: options
        ) else { return [] }

        let atDepthLimit = currentDepth + 1 >= maxDepth
        var items: [FileItem] = []
        for case let url as URL in contents {
            try Task.checkCancellation()
            guard !ignoredNames.contains(url.lastPathComponent) else { continue }
            guard remainingItems > 0 else {
                isTruncated = true
                break
            }
            remainingItems -= 1
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true
            var children: [FileItem]?
            // Links can escape the project or lead back to an ancestor.
            if isDirectory, !atDepthLimit, values?.isSymbolicLink != true {
                children = try buildTree(
                    at: url, showHiddenFiles: showHiddenFiles, maxDepth: maxDepth,
                    currentDepth: currentDepth + 1, remainingItems: &remainingItems,
                    isTruncated: &isTruncated
                )
            }
            items.append(FileItem(name: url.lastPathComponent, url: url, isDirectory: isDirectory, children: children))
        }
        try Task.checkCancellation()
        return items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static let ignoredNames: Set<String> = [
        ".DS_Store", ".git", "node_modules", ".build", "DerivedData",
        "Pods", "__pycache__", ".venv", "venv", ".svn", ".hg", "target",
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
        let isDir = values?.isDirectory == true
        let key: NSString = isDir ? "__dir__" : (pathExtension.lowercased() as NSString)
        if let cached = fileIconCache.object(forKey: key) { return cached }
        let image: NSImage = isDir
            ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: pathExtension.lowercased()) ?? .data)
        fileIconCache.setObject(image, forKey: key)
        return image
    }

    var isPreviewableImage: Bool {
        FileTypeSets.imageExtensions.contains(pathExtension.lowercased())
    }

    var isKnownBinary: Bool {
        FileTypeSets.binaryExtensions.contains(pathExtension.lowercased())
    }
}

/// Caches the NSImage returned by `URL.fileIcon` so SwiftUI sees a stable
/// instance across body recomputes. Without this, every body re-render calls
/// `NSWorkspace.icon(for:)` which returns a fresh NSImage, causing visible
/// icon flashes in lists (search results, git changes, file tree) whenever
/// any parent state — like a disclosure toggle — invalidates the view.
private let fileIconCache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 200
    return cache
}()

enum FileTypeSets {
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "ico", "icns", "svg",
    ]

    static let binaryExtensions: Set<String> = [
        "mp4", "mov", "avi", "mkv", "webm", "m4v", "mp3", "wav", "flac", "m4a", "aac", "ogg",
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso",
        "sqlite", "sqlite3", "db", "pdf", "exe", "dylib", "so", "o", "a",
        "xlsx", "xls", "docx", "doc", "pptx", "ppt", "pages", "numbers", "key", "keynote",
        "parquet", "arrow", "feather", "npy", "npz", "pkl", "h5", "hdf5",
        "ttf", "otf", "woff", "woff2",
    ]
}

extension GitChangeKind {

    /// Higher = more important. Used to pick the dominant status for folders.
    nonisolated var priority: Int {
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
