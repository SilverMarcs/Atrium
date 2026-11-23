import Foundation

/// Reads, and on the host itself writes, files inside a project or a linked
/// worktree of one of its repositories. Paths are the host's absolute paths.
nonisolated enum FileRequest: Codable, Sendable {
    /// A folder's entries, once. Follow `HostTopic.directory` to keep them current.
    case list(path: String)
    /// Files whose name matches, below `root`, up to `HostProtocol.maxFoundFiles`.
    case find(root: String, query: String)
    /// Lines containing `query` in files below `root`, up to the search caps.
    case search(root: String, query: String)
    case read(path: String)
    /// Resolves a link printed by an agent or tool to a file in the project:
    /// absolute, `~/`, or relative to `directory`, with an optional `:line` suffix.
    case resolveLink(String, directory: String?)
    // Only the host itself may change files.
    case write(path: String, text: String)
    case create(inFolder: String, isFolder: Bool)
    case rename(path: String, to: String)
    case duplicate(path: String)
    case trash(path: String)
}

nonisolated enum FileReply: Codable, Sendable {
    case done
    case entries([FileEntry])
    /// Paths relative to the root searched.
    case found([String], isTruncated: Bool)
    case matches([FileSearchResult], isTruncated: Bool)
    case preview(FilePreview)
    case path(String)
    case location(path: String, line: Int?)
    case notFound
}
