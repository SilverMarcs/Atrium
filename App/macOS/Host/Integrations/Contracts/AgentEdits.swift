import Foundation

/// The folders an agent changed files or committed in, and when it last did
/// in each, and the pull requests its commands opened. Only the newest few
/// folders are kept: they're enough to tell which checkouts a task worked in.
nonisolated struct AgentEdits: Codable, Sendable, Equatable {
    private(set) var folders: [String: Date] = [:]
    private(set) var pullRequests: Set<URL> = []

    private static let limit = 24

    /// The folders, the most recently edited first.
    var newestFirst: [String] {
        folders.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    /// Records an edit of the file at an absolute path.
    mutating func record(file path: String, at date: Date) {
        guard path.hasPrefix("/") else { return }
        record(folder: URL(filePath: path).deletingLastPathComponent().path(percentEncoded: false), at: date)
    }

    /// Records what a shell command did to repositories.
    mutating func record(_ command: AgentShellCommand, output: String, at date: Date) {
        for folder in command.repositoryFolders { record(folder: folder, at: date) }
        pullRequests.formUnion(command.openedPullRequests(output: output))
    }

    mutating func merge(_ other: AgentEdits) {
        for (folder, date) in other.folders { record(folder: folder, at: date) }
        pullRequests.formUnion(other.pullRequests)
    }

    private mutating func record(folder: String, at date: Date) {
        let folder = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        if let previous = folders[folder], previous >= date { return }
        folders[folder] = date
        if folders.count > Self.limit, let oldest = folders.min(by: { $0.value < $1.value })?.key {
            folders[oldest] = nil
        }
    }
}

nonisolated extension AgentEdits {
    private enum CodingKeys: String, CodingKey {
        case folders, pullRequests
    }

    /// Threads retained from before pull requests were recorded have none.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folders = try container.decode([String: Date].self, forKey: .folders)
        pullRequests = try container.decodeIfPresent(Set<URL>.self, forKey: .pullRequests) ?? []
    }
}
