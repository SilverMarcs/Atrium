import Foundation

/// The folders an agent changed files in with its edit tools, and when it
/// last did in each. Only the newest few are kept: they're enough to tell
/// which checkouts a task worked in.
nonisolated struct AgentEdits: Codable, Sendable, Equatable {
    private(set) var folders: [String: Date] = [:]

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

    mutating func merge(_ other: AgentEdits) {
        for (folder, date) in other.folders { record(folder: folder, at: date) }
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
